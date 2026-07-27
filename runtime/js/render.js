// render.js : WebGL2 perspective raymarcher over the 128x128x64 volume.
//
// Matches the original Voxatron look (iso-defender/game.jpg): perspective
// camera from above-front, per-face flat shading (tops brightest), soft
// straight-down drop shadows on the ground, volume floating in black.
// The volume uploads as an R8UI 3D texture (value = paletteIndex+1, 0=empty)
// and a fragment-shader DDA walks it front-to-back.
import { VW, VD, VH } from './volume.js';

// Ground policy. The plane is re-derived every frame, so a mode that flips
// between two candidates would make the shadows pop.
//
// A flat settling window is the wrong tool though: a cart changing scene (a
// title screen to a level) genuinely moves its ground, and half a second of
// shadows cast on the old plane is very visible. So confidence decides — a
// plane that dominates the occupied columns is unambiguous and adopted at
// once, and only a marginal reading has to hold for SETTLE frames. Below
// MIN_COVERAGE there is no credible ground at all, and no shadows beat shadows
// cast onto an arbitrary plane.
const GROUND_SETTLE = 8;
const MIN_COVERAGE = 0.25;
const SURE_COVERAGE = 0.5;
const NO_GROUND = 1e6;   // past the volume, so the shader's receiver test never fires

// PICO-8 palette
const PAL = [
  0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7,
  0xFFF1E8, 0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C,
  0xFF77A8, 0xFFCCAA,
];

const VS = `#version 300 es
void main() {
  const vec2 p[3] = vec2[3](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
  gl_Position = vec4(p[gl_VertexID], 0.0, 1.0);
}`;

const FS = `#version 300 es
precision highp float;
precision highp int;
uniform highp usampler3D uVol;
uniform sampler2D uShadow;
uniform vec3 uPal[16];
uniform vec3 uCamPos, uCamR, uCamU, uCamF;
uniform vec2 uHalfTan;
uniform vec2 uRes;
uniform float uGroundZ;
out vec4 fragColor;

void main() {
  vec2 ndc = (gl_FragCoord.xy / uRes) * 2.0 - 1.0;
  vec3 rd = normalize(uCamF + uCamR * ndc.x * uHalfTan.x
                            + uCamU * ndc.y * uHalfTan.y);
  // avoid div-by-zero without changing direction meaningfully
  rd = mix(rd, vec3(1e-6), vec3(lessThan(abs(rd), vec3(1e-6))));
  vec3 ro = uCamPos;
  vec3 inv = 1.0 / rd;
  vec3 bmax = vec3(${VW}.0, ${VD}.0, ${VH}.0);
  vec3 t0 = (vec3(0.0) - ro) * inv, t1 = (bmax - ro) * inv;
  vec3 tmin3 = min(t0, t1), tmax3 = max(t0, t1);
  float tEnter = max(max(tmin3.x, tmin3.y), tmin3.z);
  float tExit  = min(min(tmax3.x, tmax3.y), tmax3.z);
  fragColor = vec4(0.0, 0.0, 0.0, 1.0);
  if (tExit <= max(tEnter, 0.0)) return;

  float t = max(tEnter, 0.0) + 1e-3;
  vec3 p = ro + rd * t;
  ivec3 cell = clamp(ivec3(floor(p)), ivec3(0), ivec3(${VW - 1}, ${VD - 1}, ${VH - 1}));
  ivec3 stp = ivec3(sign(rd));
  vec3 tDelta = abs(inv);
  vec3 tMax = t + (mix(p - vec3(cell), vec3(cell) + 1.0 - p,
                       vec3(greaterThan(rd, vec3(0.0))))) * tDelta;
  int axis = (tEnter == tmin3.x) ? 0 : (tEnter == tmin3.y) ? 1 : 2;

  for (int i = 0; i < 320; i++) {
    uint v = texelFetch(uVol, cell, 0).r;
    if (v > 0u) {
      vec3 col = uPal[int(v) - 1];
      float lit = (axis == 2) ? (rd.z > 0.0 ? 1.0 : 0.5)
                : (axis == 1) ? 0.80 : 0.66;
      if (float(cell.z) >= uGroundZ - 0.5) {
        float s = texture(uShadow, (vec2(cell.xy) + 0.5) / ${VW}.0).r;
        lit *= 1.0 - 0.45 * s;
      }
      fragColor = vec4(col * lit, 1.0);
      return;
    }
    if (tMax.x < tMax.y && tMax.x < tMax.z) {
      cell.x += stp.x; tMax.x += tDelta.x; axis = 0;
      if (cell.x < 0 || cell.x >= ${VW}) break;
    } else if (tMax.y < tMax.z) {
      cell.y += stp.y; tMax.y += tDelta.y; axis = 1;
      if (cell.y < 0 || cell.y >= ${VD}) break;
    } else {
      cell.z += stp.z; tMax.z += tDelta.z; axis = 2;
      if (cell.z < 0 || cell.z >= ${VH}) break;
    }
  }
}`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))
    throw new Error(gl.getShaderInfoLog(s));
  return s;
}

export class Renderer {
  constructor(canvas, opts = {}) {
    const gl = this.gl = canvas.getContext('webgl2', { antialias: false });
    if (!gl) throw new Error('WebGL2 unavailable');

    const prog = gl.createProgram();
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VS));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FS));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS))
      throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    this.u = (n) => gl.getUniformLocation(prog, n);

    // volume texture: R8UI 3D
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    this.volTex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_3D, this.volTex);
    gl.texStorage3D(gl.TEXTURE_3D, 1, gl.R8UI, VW, VD, VH);
    gl.texParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    // shadow map: R8, LINEAR filter gives free extra softness
    this.shadowTex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.shadowTex);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.R8, VW, VD);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    gl.uniform1i(this.u('uVol'), 0);
    gl.uniform1i(this.u('uShadow'), 1);
    this.setGround(opts.ground);
    const pal = new Float32Array(48);
    PAL.forEach((c, i) => {
      pal[i * 3] = (c >> 16) / 255;
      pal[i * 3 + 1] = ((c >> 8) & 255) / 255;
      pal[i * 3 + 2] = (c & 255) / 255;
    });
    gl.uniform3fv(this.u('uPal[0]'), pal);
    gl.uniform2f(this.u('uRes'), canvas.width, canvas.height);
    gl.viewport(0, 0, canvas.width, canvas.height);

    this.setCamera(opts);
  }

  // camera from above-front, world-up = -z (z=0 is the top of the volume)
  setCamera({ pos = [64, 252, -58], target = [64, 58, 38], fovDeg = 21,
              aspect = 4 / 3 } = {}) {
    const gl = this.gl;
    const sub = (a, b) => a.map((v, i) => v - b[i]);
    const norm = (a) => {
      const l = Math.hypot(...a); return a.map(v => v / l);
    };
    const cross = (a, b) => [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0],
    ];
    const F = norm(sub(target, pos));
    const R = norm(cross(F, [0, 0, -1]));
    const U = cross(R, F);
    gl.uniform3fv(this.u('uCamPos'), pos);
    gl.uniform3fv(this.u('uCamR'), R);
    gl.uniform3fv(this.u('uCamU'), U);
    gl.uniform3fv(this.u('uCamF'), F);
    const ht = Math.tan((fovDeg * Math.PI) / 360);
    gl.uniform2f(this.u('uHalfTan'), ht * aspect, ht);
  }

  // policy: {mode:'auto'} (default, derive per frame), {mode:'fixed', z}, or
  // {mode:'off'} to disable drop shadows entirely
  setGround(policy) {
    this.ground = policy || { mode: 'auto' };
    this.groundZ = this.ground.mode === 'fixed' ? this.ground.z : NO_GROUND;
    this.groundSettled = this.ground.mode !== 'auto';
    this.candidate = NaN;
    this.candidateFor = 0;
  }

  resolveGround(volume) {
    const g = this.ground;
    if (g.mode === 'off') return NO_GROUND;
    if (g.mode === 'fixed') return g.z;
    const p = volume.groundPlane();
    // z=0 is the top of the volume, so nothing can ever be above it to cast:
    // treat it as no ground rather than blurring a map that is always empty
    const z = p && p.coverage >= MIN_COVERAGE && p.z > 0 ? p.z : NO_GROUND;
    if (z === this.groundZ) { this.candidateFor = 0; return this.groundZ; }
    // adopt the first reading outright too, or shadows fade in over the
    // settling window every time a cart loads
    if (!this.groundSettled || (z !== NO_GROUND && p.coverage >= SURE_COVERAGE)) {
      this.groundSettled = true;
      this.groundZ = z;
      this.candidateFor = 0;
      return z;
    }
    if (z === this.candidate) {
      if (++this.candidateFor >= GROUND_SETTLE) { this.groundZ = z; this.candidateFor = 0; }
    } else {
      this.candidate = z; this.candidateFor = 1;
    }
    return this.groundZ;
  }

  frame(volume) {
    const gl = this.gl;
    const groundZ = this.resolveGround(volume);
    gl.uniform1f(this.u('uGroundZ'), groundZ);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_3D, this.volTex);
    gl.texSubImage3D(gl.TEXTURE_3D, 0, 0, 0, 0, VW, VD, VH,
                     gl.RED_INTEGER, gl.UNSIGNED_BYTE, volume.data);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.shadowTex);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, VW, VD,
                     gl.RED, gl.UNSIGNED_BYTE, volume.buildShadow(groundZ));
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}
