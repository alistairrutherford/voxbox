// volume.js : the display volume + all Voxatron draw primitives.
//
// 128(x) x 128(y=depth, 0=back wall) x 64(z=height, 0=TOP) voxels.
// Stored value = paletteIndex + 1 so that PICO-8 color 0 (black) is a real
// voxel distinct from empty (0).  minZ[column] tracks the topmost occupied
// voxel per (x,y) for the drop-shadow map; clv() resets it each frame.
import { FONT, ADVANCE } from './font.js';

export const VW = 128, VD = 128, VH = 64;
const XY = VW * VD;

export class Volume {
  constructor() {
    this.data = new Uint8Array(VW * VD * VH);
    this.minZ = new Uint8Array(XY).fill(255);
    this.shadow = new Uint8Array(XY);
    this.sliceY = 0;
  }

  clv() {
    this.data.fill(0);
    this.minZ.fill(255);
  }

  vset(x, y, z, c) {
    x = Math.floor(x); y = Math.floor(y); z = Math.floor(z);
    if (x < 0 || x >= VW || y < 0 || y >= VD || z < 0 || z >= VH) return;
    this.data[x + y * VW + z * XY] = ((c || 0) & 15) + 1;
    const i = x + y * VW;
    if (z < this.minZ[i]) this.minZ[i] = z;
  }

  vget(x, y, z) {
    x = Math.floor(x); y = Math.floor(y); z = Math.floor(z);
    if (x < 0 || x >= VW || y < 0 || y >= VD || z < 0 || z >= VH) return 0;
    const v = this.data[x + y * VW + z * XY];
    return v === 0 ? 0 : v - 1;
  }

  boxfill(x0, y0, z0, x1, y1, z1, c) {
    x0 = Math.floor(x0); y0 = Math.floor(y0); z0 = Math.floor(z0);
    x1 = Math.floor(x1); y1 = Math.floor(y1); z1 = Math.floor(z1);
    if (x0 > x1) [x0, x1] = [x1, x0];
    if (y0 > y1) [y0, y1] = [y1, y0];
    if (z0 > z1) [z0, z1] = [z1, z0];
    x0 = Math.max(x0, 0); x1 = Math.min(x1, VW - 1);
    y0 = Math.max(y0, 0); y1 = Math.min(y1, VD - 1);
    z0 = Math.max(z0, 0); z1 = Math.min(z1, VH - 1);
    if (x0 > x1 || y0 > y1 || z0 > z1) return;
    const v = ((c || 0) & 15) + 1;
    for (let z = z0; z <= z1; z++) {
      const zb = z * XY;
      for (let y = y0; y <= y1; y++) {
        const o = zb + y * VW;
        this.data.fill(v, o + x0, o + x1 + 1);
      }
    }
    for (let y = y0; y <= y1; y++) {
      const row = y * VW;
      for (let x = x0; x <= x1; x++) {
        const i = row + x;
        if (z0 < this.minZ[i]) this.minZ[i] = z0;
      }
    }
  }

  // hollow box = 12-edge wireframe (the cart draws the landing pad rim with
  // it: gray boxfill plate + yellow box() on the same flat rect)
  box(x0, y0, z0, x1, y1, z1, c) {
    const e = (ax, ay, az, bx, by, bz) => this.line3d(ax, ay, az, bx, by, bz, c);
    e(x0, y0, z0, x1, y0, z0); e(x0, y1, z0, x1, y1, z0);
    e(x0, y0, z1, x1, y0, z1); e(x0, y1, z1, x1, y1, z1);
    e(x0, y0, z0, x0, y1, z0); e(x1, y0, z0, x1, y1, z0);
    e(x0, y0, z1, x0, y1, z1); e(x1, y0, z1, x1, y1, z1);
    e(x0, y0, z0, x0, y0, z1); e(x1, y0, z0, x1, y0, z1);
    e(x0, y1, z0, x0, y1, z1); e(x1, y1, z0, x1, y1, z1);
  }

  sphere(cx, cy, cz, r, c) {
    r = Math.abs(r || 0);
    const r2 = r * r + 0.5;   // fudge keeps r=1 a 7-voxel ball, not a point
    const x0 = Math.ceil(cx - r), x1 = Math.floor(cx + r);
    const y0 = Math.ceil(cy - r), y1 = Math.floor(cy + r);
    const z0 = Math.ceil(cz - r), z1 = Math.floor(cz + r);
    for (let z = z0; z <= z1; z++) {
      const dz = z - cz;
      for (let y = y0; y <= y1; y++) {
        const dy = y - cy, d2 = dy * dy + dz * dz;
        if (d2 > r2) continue;
        for (let x = x0; x <= x1; x++) {
          const dx = x - cx;
          if (dx * dx + d2 <= r2) this.vset(x, y, z, c);
        }
      }
    }
  }

  line3d(x0, y0, z0, x1, y1, z1, c) {
    const steps = Math.max(
      Math.abs(x1 - x0), Math.abs(y1 - y0), Math.abs(z1 - z0)) | 0;
    if (steps === 0) { this.vset(x0, y0, z0, c); return; }
    for (let i = 0; i <= steps; i++) {
      const t = i / steps;
      this.vset(Math.round(x0 + (x1 - x0) * t),
                Math.round(y0 + (y1 - y0) * t),
                Math.round(z0 + (z1 - z0) * t), c);
    }
  }

  // ---- 2D ops on the current y slice (coords are x, z) -------------------
  setSlice(y) {
    this.sliceY = Math.max(0, Math.min(VD - 1, Math.floor(y || 0)));
  }

  pset(x, z, c) { this.vset(x, this.sliceY, z, c); }

  line(x0, z0, x1, z1, c) {
    const steps = Math.max(Math.abs(x1 - x0), Math.abs(z1 - z0)) | 0;
    if (steps === 0) { this.pset(x0, z0, c); return; }
    for (let i = 0; i <= steps; i++) {
      const t = i / steps;
      this.pset(Math.round(x0 + (x1 - x0) * t),
                Math.round(z0 + (z1 - z0) * t), c);
    }
  }

  circ(cx, cz, r, c) {
    const n = Math.max(8, Math.ceil(r * 8));
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2;
      this.pset(cx + Math.cos(a) * r, cz + Math.sin(a) * r, c);
    }
  }

  circfill(cx, cz, r, c) {
    for (let z = Math.ceil(cz - r); z <= Math.floor(cz + r); z++)
      for (let x = Math.ceil(cx - r); x <= Math.floor(cx + r); x++)
        if ((x - cx) ** 2 + (z - cz) ** 2 <= r * r + 0.5) this.pset(x, z, c);
  }

  print(s, x, z, c) {
    s = String(s).toUpperCase();
    x = Math.floor(x); z = Math.floor(z);
    for (const ch of s) {
      const g = FONT[ch];
      if (g) {
        for (let r = 0; r < 5; r++) {
          const bits = g[r];
          if (bits & 0b100) this.pset(x, z + r, c);
          if (bits & 0b010) this.pset(x + 1, z + r, c);
          if (bits & 0b001) this.pset(x + 2, z + r, c);
        }
      }
      x += ADVANCE;
    }
  }

  // ---- ground plane ------------------------------------------------------
  // Where the ground is was never a platform constant — iso-defender happens
  // to put it at z=50 and another cart will not, so it is derived rather than
  // declared. In a Voxatron-style scene the ground is the flat slab that most
  // columns' topmost voxel belongs to, so the *mode* of minZ is the plane.
  // `coverage` (its share of occupied columns) is how the caller tells a real
  // ground slab apart from a cart that is just floating objects in the void.
  groundPlane() {
    const { minZ } = this;
    const hist = new Int32Array(VH);
    let occupied = 0;
    for (let i = 0; i < XY; i++) {
      const z = minZ[i];
      if (z >= VH) continue;              // 255 = empty column
      hist[z]++; occupied++;
    }
    if (!occupied) return null;
    let best = 0;
    for (let z = 1; z < VH; z++) if (hist[z] > hist[best]) best = z;
    return { z: best, coverage: hist[best] / occupied };
  }

  // ---- drop shadow map: blurred column occupancy above ground ------------
  // A groundZ at or past the volume floor means "no ground": nothing can
  // receive a shadow, so skip the blur entirely rather than computing a map
  // the shader will ignore.
  buildShadow(groundZ) {
    const { minZ, shadow } = this;
    if (!(groundZ < VH)) { shadow.fill(0); return shadow; }
    for (let y = 0; y < VD; y++) {
      const row = y * VW;
      for (let x = 0; x < VW; x++) {
        let sum = 0;
        for (let dy = -1; dy <= 1; dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= VD) continue;
          const rr = yy * VW;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx < 0 || xx >= VW) continue;
            if (minZ[rr + xx] < groundZ) sum++;
          }
        }
        shadow[row + x] = (sum * 255 / 9) | 0;
      }
    }
    return shadow;
  }
}
