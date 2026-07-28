-- voxel defender : 01_config
-- constants, palette, level + wave data
-- numbers stay < 32767 (pico-8 style 16.16 fixed point)

-- world -------------------------------------------------------
WRAP     = 512          -- looping arena width (world x wraps)
GROUND_Z = 50           -- voxel z of the ground surface (z=0 is TOP)
Y_MIN    = 14           -- playfield depth band (screen y)
Y_MAX    = 118
ALT_MAX  = 40           -- max flying altitude above ground
HOVER    = 12           -- player hover altitude
SCR_W    = 128

-- buttons (voxatron: 0..5 = left right up down x o) -----------
B_L=0 B_R=1 B_U=2 B_D=3 B_FIRE=4 B_BOMB=5

-- pico-8 palette indices --------------------------------------
C_BLK=0 C_DBLU=1 C_PUR=2 C_DGRN=3 C_BRN=4 C_DGRY=5 C_GRY=6 C_WHT=7
C_RED=8 C_ORG=9 C_YEL=10 C_GRN=11 C_BLU=12 C_IND=13 C_PNK=14 C_PCH=15

-- scoring (units of 10 points: 15 == 150 pts) -----------------
PTS={lander=15,mutant=15,bomber=25,pod=100,swarmer=15,baiter=20,
     mine=5,guardian=500,overmind=1000,
     catch=50,deliver=50,survive=10}
EXTRA_LIFE_EVERY=1000   -- score units (== 10,000 points)

-- player tuning ------------------------------------------------
P_ACC=0.22 P_FRIC=0.88 P_ICE_FRIC=0.965 P_MAXSPD=2.6
P_FIRE_CD=5             -- frames between shots
P_SHOT_SPD=6 P_SHOT_LIFE=26
START_LIVES=3 START_BOMBS=3 SHIELD_MAX=3
RESPAWN_T=60 INVULN_T=75
CARRY_MAX=3

-- enemy base speeds (scaled by level.spd) ----------------------
E_SPD={lander=0.55,mutant=1.5,bomber=0.7,pod=0.35,swarmer=1.9,baiter=2.3}
E_LIFE={lander=1,mutant=1,bomber=2,pod=2,swarmer=1,baiter=2}
E_RAD={lander=4,mutant=4,bomber=5,pod=5,swarmer=2,baiter=4}

BAITER_AFTER=45*30      -- frames of wave time before baiters appear
BAITER_EVERY=15*30

PMAX=220                -- particle pool size
EMAX=24                 -- max live enemies

-- level table ---------------------------------------------------
-- cols = {ground, ground2, feat1, feat2, glow}
-- amb  = ambient particle style, haz = level hazard
LEVELS={
 {name="meadow landing", cols={C_GRN,C_DGRN,C_PNK,C_YEL,C_WHT},
  amb="pollen", haz="none", colonists=8, spd=1,
  waves={{lander=4},{lander=6}}},

 {name="sunset dunes", cols={C_ORG,C_BRN,C_PCH,C_DGRN,C_YEL},
  amb="sand", haz="none", colonists=8, spd=1.05,
  waves={{lander=4,bomber=1},{lander=5,bomber=2}}},

 {name="crystal shore", cols={C_BLU,C_DBLU,C_WHT,C_PNK,C_GRY},
  amb="glint", haz="none", colonists=7, spd=1.1,
  waves={{lander=4,pod=1},{lander=5,bomber=1,pod=1},{lander=6,pod=2}}},

 {name="mushroom vale", cols={C_PUR,C_DBLU,C_PNK,C_GRN,C_YEL},
  amb="spore", haz="none", colonists=7, spd=1.15,
  waves={{lander=5,pod=1},{lander=5,bomber=2,pod=1},
         {lander=6,pod=2,bomber=1}}},

 {name="sky fortress", cols={C_ORG,C_BRN,C_YEL,C_GRY,C_WHT},
  amb="cloud", haz="none", colonists=6, spd=1.2, boss="guardian",
  waves={{lander=5,bomber=2},{lander=6,pod=2},
         {lander=6,bomber=2,pod=2}}},

 {name="frostbite ridge", cols={C_WHT,C_GRY,C_BLU,C_PNK,C_YEL},
  amb="snow", haz="ice", colonists=6, spd=1.25,
  waves={{lander=6,pod=1},{lander=6,bomber=2,pod=1},
         {lander=7,pod=2,bomber=2}}},

 {name="magma basin", cols={C_DGRY,C_BLK,C_RED,C_ORG,C_YEL},
  amb="ember", haz="geyser", colonists=6, spd=1.3,
  waves={{lander=5,bomber=2},{lander=6,pod=1,bomber=2},
         {lander=6,pod=2,swarmer=2},{lander=7,pod=2,bomber=2}}},

 {name="neon ruins", cols={C_DBLU,C_BLK,C_PNK,C_BLU,C_GRN},
  amb="neon", haz="dark", colonists=5, spd=1.4,
  waves={{lander=5,mutant=1},{lander=6,mutant=2,bomber=2},
         {lander=6,pod=2,mutant=2},{lander=7,pod=2,bomber=2,mutant=3}}},

 {name="storm peaks", cols={C_GRY,C_DGRY,C_DBLU,C_YEL,C_WHT},
  amb="rain", haz="lightning", colonists=5, spd=1.5,
  waves={{lander=6,bomber=2},{lander=6,pod=2,mutant=2},
         {lander=7,bomber=3,pod=1},{lander=7,pod=2,mutant=3,bomber=2}}},

 {name="the mothership", cols={C_DGRN,C_BLK,C_GRN,C_PUR,C_YEL},
  amb="mote", haz="none", colonists=4, spd=1.6, boss="overmind",
  waves={{lander=6,mutant=2},{lander=6,bomber=3,pod=1},
         {lander=7,pod=2,swarmer=4,mutant=2},{lander=7,bomber=3,pod=2,mutant=3},
         {lander=8,pod=3,bomber=2,mutant=4}}},
}
-- voxel defender : 02_util
-- helpers: wrap math, safe audio, hud text, misc

function wrapx(x)
 while x<0 do x=x+WRAP end
 while x>=WRAP do x=x-WRAP end
 return x
end

-- shortest signed delta from a to b on the looping x axis
function wdelta(a,b)
 local d=b-a
 if d>WRAP/2 then d=d-WRAP end
 if d<-WRAP/2 then d=d+WRAP end
 return d
end

function dist2(dx,dy) return dx*dx+dy*dy end

function clamp(v,a,b) if v<a then return a end if v>b then return b end return v end

function nstr(n) return ""..flr(n) end

-- score is stored in units of 10 points -> append a zero to display
function score_str(units) return nstr(units).."0" end

-- audio: never crash if a sound/music resource isn't in the cart yet
function sfx_safe(name)
 local ok=pcall(play_sound,name)
 return ok
end

function music_safe(name,fade)
 pcall(play_music,name,fade)
end

-- world x -> screen x relative to camera (nil if off screen)
function to_screen(wx)
 local sx=wdelta(cam_x,wx)
 if sx<-20 or sx>SCR_W+20 then return nil end
 return sx
end

-- hud text drawn on the back wall (vertical slices y=0,1 for thickness)
function hud_print(s,x,z,col)
 set_draw_slice(0,true) print(s,x,z,col)
 set_draw_slice(1,true) print(s,x,z,col)
end

function hud_pset(x,z,col)
 set_draw_slice(0,true) pset(x,z,col)
 set_draw_slice(1,true) pset(x,z,col)
end

function hud_line(x0,z0,x1,z1,col)
 set_draw_slice(0,true) line(x0,z0,x1,z1,col)
 set_draw_slice(1,true) line(x0,z0,x1,z1,col)
end

-- floating world-space text (score popups, "rescued!")
function world_print(s,sx,sy,sz,col)
 sy=flr(clamp(sy,0,127))
 set_draw_slice(sy,true)
 print(s,sx-#s*2,sz,col)
end

-- 8-way facing from input vector -> angle 0..1 (0 = east/right)
function dir_to_ang(dx,dy)
 if dx==0 and dy==0 then return nil end
 return atan2(dx,dy)
end

-- edge-detected buttons (voxatron button() has no btnp)
prev_btn={} cur_btn={}
function poll_buttons()
 for i=0,5 do
  prev_btn[i]=cur_btn[i]
  cur_btn[i]=button(i)>0
 end
end
function btnh(i) return cur_btn[i] end                 -- held
function btnp8(i) return cur_btn[i] and not prev_btn[i] end -- pressed
-- voxel defender : 03_particles
-- pooled voxel particle system + effect recipes

parts={}      -- fixed pool, recycled
p_head=1

function particles_init()
 parts={}
 for i=1,PMAX do
  parts[i]={live=false}
 end
 p_head=1
end

-- x,y in world coords, alt above ground. cols = {c1,c2,..} cycled over life
function pspawn(x,y,alt,dx,dy,dalt,life,cols,size,grav)
 local p=parts[p_head]
 p_head=p_head+1 if p_head>PMAX then p_head=1 end
 p.live=true
 p.x=wrapx(x) p.y=y p.alt=alt
 p.dx=dx p.dy=dy p.dalt=dalt
 p.t=0 p.life=life p.cols=cols
 p.size=size or 1
 p.grav=grav or 0
end

function particles_update()
 for i=1,PMAX do
  local p=parts[i]
  if p.live then
   p.t=p.t+1
   if p.t>=p.life then
    p.live=false
   else
    p.x=wrapx(p.x+p.dx)
    p.y=p.y+p.dy
    p.dalt=p.dalt-p.grav
    p.alt=p.alt+p.dalt
    if p.alt<0 then p.alt=0 p.dalt=-p.dalt*0.4 end
    if p.alt>60 then p.live=false end
   end
  end
 end
end

function particles_draw()
 for i=1,PMAX do
  local p=parts[i]
  if p.live then
   local sx=to_screen(p.x)
   if sx then
    local col=p.cols[1+flr(p.t/p.life*#p.cols)] or p.cols[#p.cols]
    local z=GROUND_Z-p.alt
    if p.y>=0 and p.y<=127 and z>=0 and z<=63 then
     if p.size<=1 then
      vset(sx,p.y,z,col)
     else
      sphere(sx,p.y,z,p.size,col)
     end
    end
   end
  end
 end
end

-- effect recipes ------------------------------------------------

function fx_explosion(x,y,alt,n,cols,big)
 for i=1,n do
  local a=rnd(1)
  local sp=0.5+rnd(big and 2.2 or 1.4)
  pspawn(x,y,alt, cos(a)*sp, sin(a)*sp*0.6, rnd(1.6)-0.4,
         14+flr(rnd(14)), cols, 1, 0.05)
 end
 if big then
  -- expanding shockwave ring
  for i=1,24 do
   local a=i/24
   pspawn(x,y,alt, cos(a)*2.8, sin(a)*1.6, 0, 10, {C_WHT,C_YEL}, 1, 0)
  end
  -- slow colour-cycling sparks
  for i=1,10 do
   pspawn(x,y,alt+2, rnd(1)-0.5, rnd(1)-0.5, 0.8+rnd(0.8),
          30+flr(rnd(20)), {C_WHT,C_YEL,C_ORG,C_RED}, 1, 0.03)
  end
 end
 shake=max(shake, big and 6 or 3)
end

function fx_sparkle(x,y,alt)
 for i=1,12 do
  local a=rnd(1)
  pspawn(x,y,alt, cos(a)*0.6, sin(a)*0.4, 0.6+rnd(1),
         20+flr(rnd(12)), {C_YEL,C_WHT,C_YEL}, 1, 0.04)
 end
end

function fx_heart(x,y,alt)
 pspawn(x,y,alt+4, 0,0, 0.5, 26, {C_PNK,C_RED,C_PNK}, 2, 0)
end

function fx_trail(x,y,alt,boost)
 local cols=boost and {C_PNK,C_YEL,C_GRN,C_BLU} or {C_BLU,C_GRY,C_DGRY}
 pspawn(x,y,alt+rnd(2)-1, rnd(0.4)-0.2, rnd(0.4)-0.2, rnd(0.2)-0.1,
        10+flr(rnd(8)), cols, 1, 0)
end

function fx_muzzle(x,y,alt,ang)
 pspawn(x,y,alt, cos(ang)*1.5, sin(ang)*1.0, 0, 4, {C_WHT,C_YEL}, 1, 0)
end

function fx_impact(x,y,alt)
 for i=1,4 do
  pspawn(x,y,alt, rnd(1.2)-0.6, rnd(0.8)-0.4, rnd(0.8),
         8+flr(rnd(6)), {C_YEL,C_ORG}, 1, 0.06)
 end
end

function fx_beam(x,y,alt_top)
 -- rising green tractor beam column under a lander
 pspawn(x+rnd(4)-2, y+rnd(3)-1.5, rnd(alt_top),
        0,0, 0.7, 16, {C_GRN,C_WHT,C_GRN}, 1, 0)
end

function fx_confetti(x,y,alt)
 local cc={{C_RED},{C_ORG},{C_YEL},{C_GRN},{C_BLU},{C_PNK}}
 for i=1,8 do
  pspawn(x,y,alt, rnd(2)-1, rnd(1.4)-0.7, 1+rnd(1.2),
         30+flr(rnd(20)), cc[1+flr(rnd(6))], 1, 0.06)
 end
end

function fx_warp(x,y,alt)
 for i=1,20 do
  local a=i/20
  pspawn(x,y,alt, cos(a)*1.8, sin(a)*1.1, rnd(1)-0.5,
         16, {C_PNK,C_BLU,C_WHT,C_GRN}, 1, 0)
 end
end

function fx_smartbomb(x,y,alt)
 for i=1,40 do
  local a=i/40
  local sp=1.5+rnd(2)
  pspawn(x,y,alt, cos(a)*sp, sin(a)*sp*0.6, rnd(1)-0.3,
         18+flr(rnd(10)), {C_WHT,C_YEL,C_ORG}, 1, 0)
 end
 flash_t=3
 shake=8
end
-- voxel defender : 04_entities
-- player shots, enemy shots, mines, colonists, pads, score popups

shots={} eshots={} mines={} colonists={} pads={} popups={}

function entities_init()
 shots={} eshots={} mines={} colonists={} pads={} popups={}
end

-- score popups ---------------------------------------------------
function popup(x,y,alt,txt,col)
 add(popups,{x=x,y=y,alt=alt,txt=txt,col=col or C_WHT,t=0})
end

function popups_update()
 for i=#popups,1,-1 do
  local p=popups[i]
  p.t=p.t+1 p.alt=p.alt+0.4
  if p.t>36 then del(popups,p) end
 end
end

function popups_draw()
 for p in all(popups) do
  local sx=to_screen(p.x)
  if sx then
   local z=clamp(GROUND_Z-p.alt,2,60)
   world_print(p.txt,sx,p.y,z,p.col)
  end
 end
end

-- player shots ----------------------------------------------------
function fire_shot(x,y,alt,ang)
 add(shots,{x=x,y=y,alt=alt,ang=ang,
            dx=cos(ang)*P_SHOT_SPD, dy=sin(ang)*P_SHOT_SPD*0.7, t=0})
 fx_muzzle(x,y,alt,ang)
 sfx_safe("shoot")
end

function shots_update()
 for i=#shots,1,-1 do
  local s=shots[i]
  s.t=s.t+1
  s.x=wrapx(s.x+s.dx)
  s.y=clamp(s.y+s.dy,Y_MIN-6,Y_MAX+6)
  if s.t>P_SHOT_LIFE then del(shots,s) end
 end
end

function shots_draw()
 for s in all(shots) do
  local sx=to_screen(s.x)
  if sx then
   local z=GROUND_Z-s.alt
   local bx=clamp(sx-s.dx,0,127)
   line3d(bx,clamp(s.y-s.dy,0,127),z, clamp(sx,0,127),s.y,z, C_YEL)
   vset(clamp(sx,0,127),s.y,z,C_WHT)
  end
 end
end

-- enemy shots -------------------------------------------------------
function espawn_shot(x,y,alt,tx,ty,talt,spd,col)
 local d=max(1,sqrt(dist2(wdelta(x,tx),ty-y)))
 add(eshots,{x=x,y=y,alt=alt,
   dx=wdelta(x,tx)/d*spd, dy=(ty-y)/d*spd, dalt=(talt-alt)/d*spd,
   t=0,col=col or C_RED})
end

function eshots_update()
 for i=#eshots,1,-1 do
  local s=eshots[i]
  s.t=s.t+1
  s.x=wrapx(s.x+s.dx) s.y=s.y+s.dy s.alt=s.alt+s.dalt
  if s.t>90 or s.alt<0 or s.alt>50 or s.y<Y_MIN-8 or s.y>Y_MAX+8 then
   del(eshots,s)
  end
 end
end

function eshots_draw()
 for s in all(eshots) do
  local sx=to_screen(s.x)
  if sx then
   local z=GROUND_Z-s.alt
   if s.y>=0 and s.y<=127 and z>=1 and z<=62 then
    vset(clamp(sx,0,127),s.y,z,s.col)
    if s.t%2==0 then vset(clamp(sx,0,127),s.y,z-1,C_WHT) end
   end
  end
 end
end

-- mines (laid by bombers) -------------------------------------------
function lay_mine(x,y,alt)
 add(mines,{x=x,y=y,alt=alt,t=0})
end

function mines_update()
 for i=#mines,1,-1 do
  local m=mines[i]
  m.t=m.t+1
  if m.t>20*30 then
   fx_explosion(m.x,m.y,m.alt,6,{C_RED,C_ORG,C_DGRY},false)
   del(mines,m)
  end
 end
end

function mines_draw()
 for m in all(mines) do
  local sx=to_screen(m.x)
  if sx and sx>=1 and sx<=126 then
   local z=GROUND_Z-m.alt
   local c=(m.t%20<10) and C_RED or C_ORG
   sphere(sx,m.y,z,1,c)
   if m.t%20<10 then vset(sx,m.y,z-2,C_WHT) end
  end
 end
end

-- landing pads --------------------------------------------------------
function pads_init(n)
 pads={}
 for i=1,n do
  add(pads,{x=wrapx(i*(WRAP/n)+rnd(20)-10),y=64})
 end
end

function nearest_pad(x)
 local best,bd=nil,32000
 for p in all(pads) do
  local d=abs(wdelta(x,p.x))
  if d<bd then bd=d best=p end
 end
 return best,bd
end

function pads_draw()
 for p in all(pads) do
  local sx=to_screen(p.x)
  if sx and sx>=6 and sx<=121 then
   boxfill(sx-5,p.y-4,GROUND_Z-1,sx+5,p.y+4,GROUND_Z-1,C_GRY)
   box(sx-5,p.y-4,GROUND_Z-1,sx+5,p.y+4,GROUND_Z-1,C_YEL)
   if frame%30<15 then
    vset(sx-5,p.y-4,GROUND_Z-2,C_GRN)
    vset(sx+5,p.y+4,GROUND_Z-2,C_GRN)
   end
  end
 end
end

-- colonists ------------------------------------------------------------
-- state: ground / abducted / falling / carried / dead
function colonists_init(n)
 colonists={}
 for i=1,n do
  add(colonists,{
   x=wrapx(i*(WRAP/n)+rnd(30)),
   y=Y_MIN+16+rnd(Y_MAX-Y_MIN-32),
   alt=0, state="ground", wt=flr(rnd(90)), wd=rnd(1), fall_from=0})
 end
end

function colonists_alive()
 local n=0
 for c in all(colonists) do
  if c.state~="dead" then n=n+1 end
 end
 return n
end

function colonists_update()
 for c in all(colonists) do
  if c.state=="ground" then
   -- gentle wander
   c.wt=c.wt-1
   if c.wt<=0 then c.wt=60+flr(rnd(90)) c.wd=rnd(1) end
   if c.wt>30 then
    c.x=wrapx(c.x+cos(c.wd)*0.15)
    c.y=clamp(c.y+sin(c.wd)*0.1,Y_MIN+8,Y_MAX-8)
   end
  elseif c.state=="falling" then
   c.dalt=(c.dalt or 0)-0.08
   c.alt=c.alt+c.dalt
   if c.alt<=0 then
    c.alt=0
    if c.fall_from>22 then
     c.state="dead"
     fx_explosion(c.x,c.y,1,8,{C_RED,C_PUR,C_DGRY},false)
     sfx_safe("hurt")
     check_hostile()
    else
     c.state="ground"
     fx_sparkle(c.x,c.y,1)
    end
   end
  elseif c.state=="carried" then
   -- follows player, stacked
   local slot=c.carry_slot or 1
   c.x=player.x c.y=player.y
   c.alt=player.alt-3-slot*3
  end
  -- "abducted" position is driven by the lander that holds it
 end
end

function colonist_draw_one(c,sx)
 local z=GROUND_Z-c.alt
 if z<2 or z>62 then return end
 -- tiny voxel person: body + head
 boxfill(sx,c.y,z-2,sx,c.y,z-1,C_BLU)
 vset(sx,c.y,z-3,C_PCH)
 if c.state=="ground" and frame%60<8 then
  vset(sx,c.y,z-4,C_WHT) -- waving
 end
end

function colonists_draw()
 for c in all(colonists) do
  if c.state~="dead" then
   local sx=to_screen(c.x)
   if sx and sx>=1 and sx<=126 then colonist_draw_one(c,sx) end
  end
 end
end
-- voxel defender : 05_enemies
-- landers, mutants, bombers, pods, swarmers, baiters + 2 bosses

enemies={}

function enemies_init() enemies={} end

function enemies_count()
 local n=0
 for e in all(enemies) do
  if e.kind~="guardian" and e.kind~="overmind" then n=n+1 end
 end
 return n
end

function boss_alive()
 for e in all(enemies) do
  if e.kind=="guardian" or e.kind=="overmind" then return true end
 end
 return false
end

function espawn(kind,x,y,alt)
 local e={kind=kind,x=wrapx(x),y=y,alt=alt,t=0,flash=0,
          life=E_LIFE[kind] or 1,state="descend",
          seed=rnd(1),shot_cd=60+flr(rnd(60))}
 if kind=="bomber" then
  e.dx=(rnd(1)<0.5 and -1 or 1)*E_SPD.bomber*level.spd
  e.mine_cd=50
 elseif kind=="guardian" then
  e.life=30
  e.parts={}
  for i=1,4 do add(e.parts,{ang=i/4,life=8,flash=0}) end
 elseif kind=="overmind" then
  e.life=50
  e.parts={}
  for i=1,6 do add(e.parts,{ang=i/6,life=6,flash=0}) end
  e.spawn_cd=150
 end
 add(enemies,e)
 fx_warp(e.x,e.y,e.alt)
 return e
end

-- spawn a wave from a table like {lander=5,bomber=2} ------------------
function spawn_wave(w)
 for kind,n in pairs(w) do
  if kind=="boss" then
   espawn(n,player and wrapx(player.x+WRAP/2) or 64,64,26)
  else
   for i=1,n do
    espawn(kind, wrapx(player.x+80+rnd(WRAP-160)),
           Y_MIN+10+rnd(Y_MAX-Y_MIN-20),
           (kind=="lander" or kind=="bomber") and 30+rnd(8) or 16+rnd(14))
   end
  end
 end
end

-- helpers ---------------------------------------------------------------
local function home(e,tx,ty,talt,spd)
 local d=max(1,sqrt(dist2(wdelta(e.x,tx),ty-e.y)))
 e.x=wrapx(e.x+wdelta(e.x,tx)/d*spd)
 e.y=clamp(e.y+(ty-e.y)/d*spd*0.7,Y_MIN,Y_MAX)
 if talt then e.alt=e.alt+clamp(talt-e.alt,-spd*0.5,spd*0.5) end
end

local function try_shoot(e,spd,col,cd)
 e.shot_cd=e.shot_cd-1
 if e.shot_cd<=0 and player_targetable() then
  e.shot_cd=cd+flr(rnd(cd))
  if abs(wdelta(e.x,player.x))<80 then
   espawn_shot(e.x,e.y,e.alt,player.x,player.y,player.alt,spd,col)
   sfx_safe("eshoot")
  end
 end
end

-- find an unclaimed grounded colonist near the lander
local function pick_victim(e)
 local best,bd=nil,32000
 for c in all(colonists) do
  if c.state=="ground" and not c.claimed then
   local d=abs(wdelta(e.x,c.x))
   if d<bd then bd=d best=c end
  end
 end
 return best
end

-- per-kind updates -------------------------------------------------------
local upd={}

upd.lander=function(e)
 local sp=E_SPD.lander*level.spd
 if e.state=="descend" then
  if not e.victim or e.victim.state~="ground" then
   if e.victim then e.victim.claimed=nil end
   e.victim=pick_victim(e)
   if e.victim then e.victim.claimed=true end
  end
  if e.victim then
   home(e,e.victim.x,e.victim.y,6,sp)
   if abs(wdelta(e.x,e.victim.x))<2 and abs(e.y-e.victim.y)<2
      and e.alt<8 then
    e.state="rise"
    e.victim.state="abducted"
    sfx_safe("alarm")
   end
  else
   -- no colonists left: hunt the player
   home(e,player.x,player.y,player.alt,sp*0.8)
  end
  try_shoot(e,1.2*level.spd,C_RED,110)
 elseif e.state=="rise" then
  e.alt=e.alt+sp*0.55
  e.victim.x=e.x e.victim.y=e.y e.victim.alt=e.alt-4
  if frame%3==0 then fx_beam(e.x,e.y,e.alt-4) end
  if e.alt>=ALT_MAX then
   -- escaped: colonist lost, lander mutates
   e.victim.state="dead" e.victim=nil
   e.kind="mutant" e.state="hunt"
   fx_explosion(e.x,e.y,e.alt,10,{C_GRN,C_PNK,C_WHT},false)
   sfx_safe("mutate")
   check_hostile()
  end
 end
end

upd.mutant=function(e)
 local sp=E_SPD.mutant*level.spd*(level.haz=="dark" and 1.2 or 1)
 local jx=cos(e.seed+e.t/40)*14
 local jy=sin(e.seed+e.t/34)*10
 home(e,player.x+jx,player.y+jy,player.alt+cos(e.t/50)*6,sp)
 try_shoot(e,1.6*level.spd,C_PNK,70)
end

upd.bomber=function(e)
 e.x=wrapx(e.x+e.dx)
 e.y=clamp(64+sin(e.seed+e.t/90)*36,Y_MIN,Y_MAX)
 e.alt=22+sin(e.seed+e.t/60)*6
 e.mine_cd=e.mine_cd-1
 if e.mine_cd<=0 then
  e.mine_cd=45+flr(rnd(30))
  lay_mine(e.x,e.y,e.alt)
  sfx_safe("mine")
 end
end

upd.pod=function(e)
 e.x=wrapx(e.x+cos(e.seed)*E_SPD.pod*level.spd)
 e.y=clamp(e.y+sin(e.seed+e.t/120)*0.3,Y_MIN,Y_MAX)
 e.alt=20+sin(e.t/80)*8
end

upd.swarmer=function(e)
 local sp=E_SPD.swarmer*level.spd
 home(e,player.x,player.y,player.alt,sp)
 e.x=wrapx(e.x+cos(e.seed+e.t/16)*1.2)
 e.y=clamp(e.y+sin(e.seed+e.t/13)*0.9,Y_MIN,Y_MAX)
end

upd.baiter=function(e)
 home(e,player.x,player.y,player.alt,E_SPD.baiter*level.spd)
 try_shoot(e,2*level.spd,C_GRN,45)
end

-- bosses -----------------------------------------------------------------
local function boss_part_pos(e,p,r)
 return wrapx(e.x+cos(p.ang+e.t/300)*r),
        e.y+sin(p.ang+e.t/300)*r*0.5,
        e.alt+cos(p.ang*2+e.t/200)*4
end

local function parts_alive(e)
 local n=0
 for p in all(e.parts) do if p.life>0 then n=n+1 end end
 return n
end

upd.guardian=function(e)
 e.x=wrapx(e.x+cos(e.t/400)*0.5)
 e.y=64+sin(e.t/300)*20
 e.alt=24+sin(e.t/180)*4
 local pa=parts_alive(e)
 for p in all(e.parts) do
  p.flash=max(0,p.flash-1)
  if p.life>0 and e.t%120==flr(p.ang*100) and player_targetable() then
   local px,py,palt=boss_part_pos(e,p,14)
   espawn_shot(px,py,palt,player.x,player.y,player.alt,1.5*level.spd,C_ORG)
  end
 end
 if pa==0 and e.t%90==0 then
  -- radial burst from exposed core
  for i=1,10 do
   local a=i/10
   espawn_shot(e.x,e.y,e.alt,
     wrapx(e.x+cos(a)*40),e.y+sin(a)*24,e.alt-6,1.6*level.spd,C_RED)
  end
  sfx_safe("eshoot")
 end
end

upd.overmind=function(e)
 local ph2=e.life<25
 e.x=wrapx(e.x+cos(e.t/(ph2 and 220 or 340))*(ph2 and 0.8 or 0.5))
 e.y=64+sin(e.t/260)*16
 e.alt=26+sin(e.t/150)*5
 for p in all(e.parts) do p.flash=max(0,p.flash-1) end
 e.spawn_cd=e.spawn_cd-1
 if e.spawn_cd<=0 and enemies_count()<EMAX-4 then
  e.spawn_cd=ph2 and 100 or 160
  espawn("swarmer",wrapx(e.x+rnd(40)-20),e.y,e.alt)
 end
 local cd=ph2 and 60 or 100
 if e.t%cd==0 then
  if parts_alive(e)>0 and player_targetable() then
   espawn_shot(e.x,e.y,e.alt,player.x,player.y,player.alt,1.8*level.spd,C_GRN)
  else
   for i=1,12 do
    local a=i/12+e.t/1000
    espawn_shot(e.x,e.y,e.alt,
      wrapx(e.x+cos(a)*40),e.y+sin(a)*24,e.alt-8,1.7*level.spd,C_GRN)
   end
  end
  sfx_safe("eshoot")
 end
end

-- hitboxes: list of {x,y,alt,rad,part} ------------------------------------
function enemy_hitboxes(e)
 if e.kind=="guardian" or e.kind=="overmind" then
  local hbs={}
  local r=(e.kind=="guardian") and 14 or 12
  for p in all(e.parts) do
   if p.life>0 then
    local px,py,palt=boss_part_pos(e,p,r)
    add(hbs,{x=px,y=py,alt=palt,rad=4,part=p})
   end
  end
  add(hbs,{x=e.x,y=e.y,alt=e.alt,rad=6,part=nil}) -- core
  return hbs
 end
 return {{x=e.x,y=e.y,alt=e.alt,rad=E_RAD[e.kind] or 4,part=nil}}
end

-- damage / death -----------------------------------------------------------
function enemy_kill(e,quiet)
 local cols={C_WHT,C_YEL,C_ORG,C_RED}
 if e.kind=="pod" then cols={C_WHT,C_PNK,C_PUR} end
 fx_explosion(e.x,e.y,e.alt,e.kind=="pod" and 20 or 14,cols,
              e.kind=="pod" or e.kind=="bomber")
 fx_confetti(e.x,e.y,e.alt)
 sfx_safe(e.kind=="pod" and "bigboom" or "boom")
 award(PTS[e.kind] or 10,e.x,e.y,e.alt)
 -- lander drops its victim
 if e.victim and e.victim.state=="abducted" then
  e.victim.state="falling" e.victim.dalt=0
  e.victim.fall_from=e.victim.alt e.victim.claimed=nil
 end
 del(enemies,e)
 -- pods burst into swarmers
 if e.kind=="pod" and not quiet then
  for i=1,4 do
   espawn("swarmer",wrapx(e.x+rnd(10)-5),clamp(e.y+rnd(10)-5,Y_MIN,Y_MAX),e.alt)
  end
 end
end

function enemy_damage(e,part)
 if part then
  part.life=part.life-1 part.flash=4
  if part.life<=0 then
   local r=(e.kind=="guardian") and 14 or 12
   local px,py,palt=boss_part_pos(e,part,r)
   fx_explosion(px,py,palt,16,{C_WHT,C_YEL,C_ORG,C_RED},true)
   sfx_safe("boom")
   award(25,px,py,palt)
  end
  return
 end
 if (e.kind=="guardian" or e.kind=="overmind") and parts_alive(e)>0 then
  fx_impact(e.x,e.y,e.alt) -- core shielded while parts remain
  return
 end
 e.life=e.life-1 e.flash=4
 if e.life<=0 then
  if e.kind=="guardian" or e.kind=="overmind" then
   boss_dying=e.kind boss_die_t=0
   boss_die_x=e.x boss_die_y=e.y boss_die_alt=e.alt
   fx_explosion(e.x,e.y,e.alt,30,{C_WHT,C_YEL,C_ORG,C_RED},true)
   award(PTS[e.kind],e.x,e.y,e.alt)
   sfx_safe("bigboom")
   del(enemies,e)
  else
   enemy_kill(e)
  end
 else
  fx_impact(e.x,e.y,e.alt)
 end
end

function enemies_update()
 for i=#enemies,1,-1 do
  local e=enemies[i]
  e.t=e.t+1
  e.flash=max(0,e.flash-1)
  local f=upd[e.kind]
  if f then f(e) end
 end
end

-- drawing --------------------------------------------------------------------
local function fc(e,col) return e.flash>0 and C_WHT or col end

local drw={}

drw.lander=function(e,sx)
 local z=GROUND_Z-e.alt
 boxfill(sx-2,e.y-1,z,sx+2,e.y+1,z,fc(e,C_GRN))
 boxfill(sx-1,e.y,z-1,sx+1,e.y,z-1,fc(e,C_DGRN))
 vset(sx,e.y,z-2,C_YEL)
 if e.state=="rise" then
  line3d(sx,e.y,z+1,sx,e.y,min(63,GROUND_Z),C_GRN)
 end
end

drw.mutant=function(e,sx)
 local z=GROUND_Z-e.alt
 local c=(frame%8<4) and C_PNK or C_RED
 boxfill(sx-2,e.y-1,z,sx+2,e.y+1,z,fc(e,c))
 vset(sx,e.y,z-1,C_WHT)
 vset(sx-2,e.y,z+1,c) vset(sx+2,e.y,z+1,c)
end

drw.bomber=function(e,sx)
 local z=GROUND_Z-e.alt
 boxfill(sx-3,e.y-1,z-1,sx+3,e.y+1,z,fc(e,C_BRN))
 boxfill(sx-1,e.y,z-2,sx+1,e.y,z-2,fc(e,C_ORG))
 vset(sx,e.y,z+1,(frame%16<8) and C_RED or C_ORG)
end

drw.pod=function(e,sx)
 local z=GROUND_Z-e.alt
 local r=2+((frame%40<20) and 1 or 0)
 sphere(sx,e.y,z,r,fc(e,C_PUR))
 vset(sx,e.y,z-r,C_PNK)
end

drw.swarmer=function(e,sx)
 local z=GROUND_Z-e.alt
 vset(sx,e.y,z,fc(e,(frame%6<3) and C_YEL or C_ORG))
 vset(sx,e.y,z-1,C_RED)
end

drw.baiter=function(e,sx)
 local z=GROUND_Z-e.alt
 local c=(frame%6<3) and C_BLU or C_GRN
 boxfill(sx-3,e.y-1,z,sx+3,e.y+1,z,fc(e,c))
 vset(sx-3,e.y,z-1,C_WHT) vset(sx+3,e.y,z-1,C_WHT)
end

local function draw_boss(e,sx,core_c,orb_c,r)
 local z=GROUND_Z-e.alt
 -- core
 sphere(sx,e.y,z,5,fc(e,core_c))
 sphere(sx,e.y,z-2,2,C_WHT)
 if parts_alive(e)>0 and frame%4<2 then
  sphere(sx,e.y,z,7,orb_c) -- shield shimmer
 end
 -- orbiting parts
 for p in all(e.parts) do
  if p.life>0 then
   local px,py,palt=boss_part_pos(e,p,r)
   local psx=to_screen(px)
   if psx and psx>=3 and psx<=124 then
    local pz=GROUND_Z-palt
    sphere(psx,py,pz,2,(p.flash>0) and C_WHT or orb_c)
    vset(psx,py,pz-2,C_YEL)
   end
  end
 end
end

drw.guardian=function(e,sx) draw_boss(e,sx,C_ORG,C_YEL,14) end
drw.overmind=function(e,sx) draw_boss(e,sx,C_DGRN,C_GRN,12) end

function enemies_draw()
 for e in all(enemies) do
  local sx=to_screen(e.x)
  if sx and sx>=4 and sx<=123 then
   local f=drw[e.kind]
   if f then f(e,sx) end
  end
 end
end
-- voxel defender : 06_player
-- the vox ranger: movement, firing, smart bomb, warp, damage, carrying

player={}

function player_init()
 player={
  x=64,y=64,alt=HOVER,dx=0,dy=0,
  facing=0, -- angle 0..1, 0=east
  fire_cd=0, shield=SHIELD_MAX, lives=START_LIVES, bombs=START_BOMBS,
  dead_t=0, invuln=0, bob=rnd(1), boost=0,
 }
end

function player_targetable()
 return player.dead_t<=0 and player.invuln<=0
end

function player_alive() return player.dead_t<=0 end

function carried_count()
 local n=0
 for c in all(colonists) do
  if c.state=="carried" then n=n+1 end
 end
 return n
end

local function drop_carried_at_pad()
 for c in all(colonists) do
  if c.state=="carried" then
   c.state="ground" c.alt=0 c.carry_slot=nil
   fx_sparkle(c.x,c.y,2) fx_heart(c.x,c.y,4)
   award(PTS.deliver,c.x,c.y,10)
   sfx_safe("deliver")
  end
 end
end

local function scatter_carried()
 for c in all(colonists) do
  if c.state=="carried" then
   c.state="falling" c.dalt=0 c.fall_from=c.alt c.carry_slot=nil
  end
 end
end

function player_hit(dmg)
 if not player_targetable() then return end
 player.shield=player.shield-(dmg or 1)
 shake=max(shake,4)
 sfx_safe("hurt")
 if player.shield<=0 then
  -- ship destroyed
  fx_explosion(player.x,player.y,player.alt,26,{C_WHT,C_YEL,C_ORG,C_RED},true)
  fx_confetti(player.x,player.y,player.alt)
  sfx_safe("bigboom")
  scatter_carried()
  player.lives=player.lives-1
  player.dead_t=RESPAWN_T
 else
  player.invuln=30
  fx_explosion(player.x,player.y,player.alt,8,{C_WHT,C_BLU},false)
 end
end

local function do_smartbomb()
 if player.bombs<=0 then return end
 player.bombs=player.bombs-1
 fx_smartbomb(player.x,player.y,player.alt)
 sfx_safe("bomb")
 -- destroy every on-screen enemy, mine and shot
 for i=#enemies,1,-1 do
  local e=enemies[i]
  local sx=to_screen(e.x)
  if sx then
   if e.kind=="guardian" or e.kind=="overmind" then
    enemy_damage(e,nil) -- bosses just take a tick of core damage
   else
    enemy_kill(e,true)  -- quiet: pods don't split under a smart bomb
   end
  end
 end
 for i=#mines,1,-1 do
  local m=mines[i]
  if to_screen(m.x) then
   fx_explosion(m.x,m.y,m.alt,6,{C_YEL,C_ORG},false)
   del(mines,m)
  end
 end
 for i=#eshots,1,-1 do
  if to_screen(eshots[i].x) then del(eshots,eshots[i]) end
 end
end

local function do_warp()
 fx_warp(player.x,player.y,player.alt)
 player.x=wrapx(rnd(WRAP))
 player.y=Y_MIN+10+rnd(Y_MAX-Y_MIN-20)
 player.dx=0 player.dy=0
 fx_warp(player.x,player.y,player.alt)
 sfx_safe("warp")
 if rnd(1)<0.15 then
  player.invuln=0
  player_hit(1) -- rough exit!
 else
  player.invuln=20
 end
end

function player_update()
 -- dead: wait then respawn
 if player.dead_t>0 then
  player.dead_t=player.dead_t-1
  if player.dead_t==0 then
   if player.lives<0 then return end
   player.shield=SHIELD_MAX
   player.invuln=INVULN_T
   player.x=wrapx(cam_x+64) player.y=64
   player.dx=0 player.dy=0
   fx_warp(player.x,player.y,player.alt)
   sfx_safe("warp")
  end
  return
 end
 player.invuln=max(0,player.invuln-1)
 player.bob=(player.bob+0.01)%1
 player.boost=max(0,player.boost-1)

 -- steering
 local ax,ay=0,0
 if btnh(B_L) then ax=ax-1 end
 if btnh(B_R) then ax=ax+1 end
 if btnh(B_U) then ay=ay-1 end
 if btnh(B_D) then ay=ay+1 end
 local fric=(level.haz=="ice") and P_ICE_FRIC or P_FRIC
 player.dx=(player.dx+ax*P_ACC)*fric
 player.dy=(player.dy+ay*P_ACC)*fric
 player.dx=clamp(player.dx,-P_MAXSPD,P_MAXSPD)
 player.dy=clamp(player.dy,-P_MAXSPD,P_MAXSPD)
 player.x=wrapx(player.x+player.dx)
 player.y=clamp(player.y+player.dy,Y_MIN,Y_MAX)
 local a=dir_to_ang(ax,ay)
 if a then player.facing=a player.boost=4 end
 player.alt=HOVER+sin(player.bob)*1.5

 -- engine trail
 if frame%2==0 then
  fx_trail(wrapx(player.x-cos(player.facing)*4),
           player.y-sin(player.facing)*2, player.alt, player.boost>2)
 end

 -- fire
 player.fire_cd=max(0,player.fire_cd-1)
 if btnh(B_FIRE) and player.fire_cd==0 then
  player.fire_cd=P_FIRE_CD
  fire_shot(wrapx(player.x+cos(player.facing)*4),
            player.y+sin(player.facing)*2, player.alt, player.facing)
 end

 -- smart bomb (o) / warp dash (hold down + o)
 if btnp8(B_BOMB) then
  if btnh(B_D) then do_warp() else do_smartbomb() end
 end

 -- catch falling colonists
 for c in all(colonists) do
  if c.state=="falling" and carried_count()<CARRY_MAX then
   if abs(wdelta(player.x,c.x))<5 and abs(player.y-c.y)<5
      and c.alt<=player.alt+4 and c.alt>=player.alt-6 then
    c.state="carried" c.carry_slot=carried_count()+1
    award(PTS.catch,c.x,c.y,c.alt)
    fx_sparkle(c.x,c.y,c.alt)
    sfx_safe("rescue")
   end
  end
 end

 -- deliver at a pad
 if carried_count()>0 then
  local p,d=nearest_pad(player.x)
  if p and d<8 and abs(player.y-p.y)<8 then
   drop_carried_at_pad()
  end
 end

 -- collisions: enemies, shots, mines
 if player_targetable() then
  for e in all(enemies) do
   for hb in all(enemy_hitboxes(e)) do
    if abs(wdelta(player.x,hb.x))<hb.rad+3
       and abs(player.y-hb.y)<hb.rad+3
       and abs(player.alt-hb.alt)<6 then
     player_hit(1)
     if e.kind=="swarmer" then enemy_kill(e) end
     break
    end
   end
  end
 end
 if player_targetable() then
  for s in all(eshots) do
   if abs(wdelta(player.x,s.x))<3 and abs(player.y-s.y)<3
      and abs(player.alt-s.alt)<4 then
    del(eshots,s) player_hit(1) break
   end
  end
  for m in all(mines) do
   if abs(wdelta(player.x,m.x))<4 and abs(player.y-m.y)<4
      and abs(player.alt-m.alt)<5 then
    fx_explosion(m.x,m.y,m.alt,10,{C_RED,C_ORG,C_YEL},false)
    del(mines,m) player_hit(1) break
   end
  end
 end
end

function player_draw()
 if not player_alive() then return end
 if player.invuln>0 and frame%4<2 then return end -- blink
 local sx=to_screen(player.x)
 if not sx then return end
 local z=GROUND_Z-player.alt
 local fx0=cos(player.facing) local fy0=sin(player.facing)
 -- hull
 boxfill(sx-2,player.y-1,z,sx+2,player.y+1,z,C_BLU)
 boxfill(sx-1,player.y,z-1,sx+1,player.y,z-1,C_WHT)
 -- nose in facing direction
 vset(clamp(sx+fx0*3,0,127),clamp(player.y+fy0*2,0,127),z,C_YEL)
 -- canopy glow
 vset(sx,player.y,z-2,(frame%20<10) and C_GRN or C_BLU)
 -- carried colonists dangle below
 for c in all(colonists) do
  if c.state=="carried" then
   local cz=GROUND_Z-c.alt
   if cz>=0 and cz<=62 then
    vset(sx,player.y,cz,C_BLU) vset(sx,player.y,cz-1,C_PCH)
   end
  end
 end
end
-- voxel defender : 07_world
-- terrain, per-level scenery, ambient particles, level hazards

features={} skydots={} geysers={} bolt=nil bolt_cd=0

function world_init()
 features={} skydots={} geysers={} bolt=nil bolt_cd=140
 -- scatter decorative scenery around the loop
 for i=1,26 do
  add(features,{
   x=wrapx(i*(WRAP/26)+rnd(14)),
   y=Y_MIN+6+rnd(Y_MAX-Y_MIN-12),
   h=3+flr(rnd(5)), w=1+flr(rnd(2)), v=rnd(1)})
 end
 -- parallax sky dots (stars / far clouds)
 for i=1,14 do
  add(skydots,{x=rnd(WRAP),z=3+flr(rnd(9)),y=4+flr(rnd(10))})
 end
 if level.haz=="geyser" then
  for i=1,4 do
   add(geysers,{x=wrapx(i*(WRAP/4)+rnd(30)),y=40+rnd(48),t=flr(rnd(240))})
  end
 end
end

local function draw_ground()
 local c=level.cols
 boxfill(0,0,GROUND_Z,127,127,63,c[2])
 boxfill(0,0,GROUND_Z,127,127,GROUND_Z,c[1])
 -- scrolling surface stripes so motion reads clearly
 local k=flr(cam_x/32)*32
 for i=-1,5 do
  local wx=k+i*32
  local sx=wdelta(cam_x,wrapx(wx))
  local x0=clamp(sx,0,127) local x1=clamp(sx+15,0,127)
  if x1>x0 then
   boxfill(x0,0,GROUND_Z,x1,127,GROUND_Z,c[2])
  end
 end
end

-- one scenery item, styled by level number
local function draw_feature(f,sx)
 local c=level.cols
 local z=GROUND_Z-1
 local lv=level_no
 if lv==1 then      -- flowers + bushes
  sphere(sx,f.y,z-f.h+1,f.w+1,C_DGRN)
  vset(sx,f.y,z-f.h,f.v<0.5 and C_PNK or C_YEL)
 elseif lv==2 then  -- cacti
  boxfill(sx,f.y,z-f.h,sx,f.y,z,C_DGRN)
  vset(sx-1,f.y,z-f.h+1,C_DGRN) vset(sx+1,f.y,z-f.h+2,C_DGRN)
  vset(sx,f.y,z-f.h-1,C_PNK)
 elseif lv==3 then  -- glowing crystals
  boxfill(sx,f.y,z-f.h,sx+f.w,f.y+1,z,c[3])
  vset(sx,f.y,z-f.h-1,(frame%30<15) and C_WHT or c[4])
 elseif lv==4 then  -- giant mushrooms
  boxfill(sx,f.y,z-f.h,sx,f.y,z,C_GRY)
  sphere(sx,f.y,z-f.h,f.w+2,c[3])
  vset(sx,f.y,z-f.h-f.w-2,C_WHT)
 elseif lv==5 then  -- brass pylons
  boxfill(sx,f.y,z-f.h-2,sx+1,f.y+1,z,C_ORG)
  vset(sx,f.y,z-f.h-3,(frame%20<10) and C_YEL or C_WHT)
 elseif lv==6 then  -- ice spikes
  boxfill(sx,f.y,z-f.h,sx+f.w,f.y+f.w,z,C_WHT)
  vset(sx,f.y,z-f.h-1,C_BLU)
 elseif lv==7 then  -- volcanic rocks
  sphere(sx,f.y,z,f.w+1,C_DGRY)
  vset(sx,f.y,z-f.w-1,(frame%24<12) and C_RED or C_ORG)
 elseif lv==8 then  -- neon ruins
  boxfill(sx,f.y,z-f.h-2,sx+2,f.y+1,z,C_DGRY)
  local nc=(f.v<0.5) and C_PNK or C_BLU
  if frame%40<32 then line3d(sx,f.y,z-f.h-2,sx+2,f.y,z-f.h-2,nc) end
 elseif lv==9 then  -- crags
  boxfill(sx,f.y,z-f.h,sx+f.w+1,f.y+f.w,z,C_DGRY)
  vset(sx,f.y,z-f.h-1,C_GRY)
 else               -- alien growths
  boxfill(sx,f.y,z-f.h,sx,f.y,z,C_DGRN)
  sphere(sx,f.y,z-f.h,1,(frame%16<8) and C_GRN or C_PUR)
 end
end

local function draw_sky()
 for d in all(skydots) do
  -- half-speed parallax
  local sx=wdelta(cam_x*0.5,d.x)
  if sx>=0 and sx<=127 then
   local col=C_WHT
   if level_no==5 then col=C_GRY
   elseif level_no==9 then col=C_DGRY
   elseif level_no==8 then col=C_DBLU end
   vset(sx,d.y,d.z,col)
  end
 end
end

-- ambient particles near the camera ------------------------------------
local function ambient()
 local a=level.amb
 local wx=wrapx(cam_x+rnd(128))
 local wy=Y_MIN+rnd(Y_MAX-Y_MIN)
 if a=="pollen" then
  if frame%4==0 then
   pspawn(wx,wy,2+rnd(20),0.1,0,0.1,40,{C_YEL,C_WHT},1,0)
  end
 elseif a=="sand" then
  if frame%3==0 then
   pspawn(wx,wy,1+rnd(6),0.8+rnd(0.6),0,0,30,{C_PCH,C_ORG},1,0)
  end
 elseif a=="glint" then
  if frame%6==0 then
   pspawn(wx,wy,1+rnd(10),0,0,0.2,16,{C_WHT,C_BLU,C_WHT},1,0)
  end
 elseif a=="spore" then
  if frame%4==0 then
   pspawn(wx,wy,rnd(25),0.15,cos(frame/60)*0.2,0.12,50,{C_PNK,C_GRN},1,0)
  end
 elseif a=="cloud" then
  if frame%10==0 then
   pspawn(wx,wy,26+rnd(12),0.4,0,0,60,{C_WHT,C_GRY},2,0)
  end
 elseif a=="snow" then
  if frame%2==0 then
   pspawn(wx,wy,30+rnd(10),0.2,0.1,-0.35,90,{C_WHT},1,0)
  end
 elseif a=="ember" then
  if frame%3==0 then
   pspawn(wx,wy,rnd(4),0.1,0,0.5+rnd(0.4),35,{C_YEL,C_ORG,C_RED,C_DGRY},1,0)
  end
 elseif a=="neon" then
  if frame%3==0 then
   pspawn(wx,wy,34,0,0,-1.6,26,{C_PNK,C_BLU},1,0)
  end
 elseif a=="rain" then
  pspawn(wx,wy,36,0.3,0,-2.2,18,{C_BLU,C_GRY},1,0)
 elseif a=="mote" then
  if frame%5==0 then
   pspawn(wx,wy,rnd(30),cos(frame/90)*0.3,0,0.1,45,{C_GRN,C_PUR},1,0)
  end
 end
end

-- hazards ----------------------------------------------------------------
local function geysers_update()
 for g in all(geysers) do
  g.t=g.t+1
  if g.t>240 then g.t=0 end
  if g.t>=180 then
   -- erupting
   if frame%2==0 then
    pspawn(g.x+rnd(4)-2,g.y+rnd(3)-1.5,1,0,0,1.8+rnd(0.8),
           22,{C_YEL,C_ORG,C_RED},1,0.05)
   end
   if player_targetable()
      and abs(wdelta(player.x,g.x))<5 and abs(player.y-g.y)<5
      and player.alt<24 then
    player_hit(1)
   end
  end
 end
end

local function geysers_draw()
 for g in all(geysers) do
  local sx=to_screen(g.x)
  if sx and sx>=2 and sx<=125 then
   if g.t>=150 and g.t<180 then
    -- warning glow
    sphere(sx,g.y,GROUND_Z-1,1,(frame%8<4) and C_RED or C_ORG)
   elseif g.t>=180 then
    line3d(sx,g.y,GROUND_Z-24,sx,g.y,GROUND_Z-1,(frame%4<2) and C_YEL or C_ORG)
   end
  end
 end
end

local function lightning_update()
 if bolt then
  bolt.t=bolt.t+1
  if bolt.t==30 then
   -- strike!
   sfx_safe("boom")
   shake=max(shake,5)
   for i=1,14 do
    pspawn(bolt.x+rnd(6)-3,bolt.y+rnd(4)-2,1,rnd(2)-1,rnd(1)-0.5,rnd(1.5),
           18,{C_WHT,C_YEL},1,0.05)
   end
   if player_targetable()
      and abs(wdelta(player.x,bolt.x))<6 and abs(player.y-bolt.y)<6 then
    player_hit(1)
   end
  end
  if bolt.t>40 then bolt=nil end
 else
  bolt_cd=bolt_cd-1
  if bolt_cd<=0 then
   bolt_cd=100+flr(rnd(120))
   bolt={x=wrapx(cam_x+rnd(128)),y=Y_MIN+10+rnd(Y_MAX-Y_MIN-20),t=0}
  end
 end
end

local function lightning_draw()
 if not bolt then return end
 local sx=to_screen(bolt.x)
 if not sx or sx<2 or sx>125 then return end
 if bolt.t<30 then
  if frame%6<3 then sphere(sx,bolt.y,GROUND_Z-1,1,C_YEL) end
 else
  local jag=flr(rnd(5))-2
  line3d(clamp(sx+jag,0,127),bolt.y,2,sx,bolt.y,GROUND_Z-1,C_WHT)
  line3d(clamp(sx-jag,0,127),bolt.y,10,sx,bolt.y,GROUND_Z-1,C_YEL)
 end
end

function world_update()
 ambient()
 if level.haz=="geyser" then geysers_update() end
 if level.haz=="lightning" then lightning_update() end
end

function world_draw()
 draw_ground()
 draw_sky()
 for f in all(features) do
  local sx=to_screen(f.x)
  if sx and sx>=4 and sx<=122 then draw_feature(f,sx) end
 end
 pads_draw()
 if level.haz=="geyser" then geysers_draw() end
 if level.haz=="lightning" then lightning_draw() end
end
-- voxel defender : 08_hud
-- hud bar, radar strip, banners, title / select / end screens

banner_txt=nil banner_t=0 banner_col=C_WHT

function set_banner(txt,frames,col)
 banner_txt=txt banner_t=frames banner_col=col or C_WHT
end

function banner_update()
 if banner_t>0 then banner_t=banner_t-1 end
end

local function draw_banner()
 if banner_t>0 and banner_txt then
  local c=(banner_t%12<6) and banner_col or C_WHT
  set_draw_slice(64,true)
  print(banner_txt,64-#banner_txt*2,18,c)
 end
end

-- radar ------------------------------------------------------------------
local RX0=14 RX1=114 RZ=8

local function radar_x(wx)
 return 64+flr(wdelta(player.x,wx)*(RX1-RX0)/WRAP)
end

local function radar_blip(wx,z,col)
 local x=radar_x(wx)
 if x>=RX0 and x<=RX1 then hud_pset(x,z,col) end
end

local function draw_radar()
 hud_line(RX0-1,RZ-3,RX0-1,RZ+3,C_DGRY)
 hud_line(RX1+1,RZ-3,RX1+1,RZ+3,C_DGRY)
 hud_line(RX0,RZ+3,RX1,RZ+3,C_DGRY)
 -- night radar flickers on the neon level
 if level.haz=="dark" and frame%40>34 then return end
 for c in all(colonists) do
  if c.state~="dead" then
   radar_blip(c.x,RZ+2,(c.state=="abducted") and ((frame%8<4) and C_WHT or C_GRN) or C_GRN)
  end
 end
 for p in all(pads) do radar_blip(p.x,RZ+2,C_YEL) end
 for e in all(enemies) do
  local col=C_RED
  if e.kind=="mutant" then col=C_PNK end
  if e.kind=="baiter" then col=C_BLU end
  if e.kind=="guardian" or e.kind=="overmind" then col=(frame%8<4) and C_ORG or C_WHT end
  radar_blip(e.x,RZ-flr(e.alt/16),col)
 end
 hud_pset(64,RZ,C_WHT) -- you
end

-- main hud ------------------------------------------------------------------
function hud_draw()
 hud_print("score "..score_str(score),2,1,C_WHT)
 hud_print("hi "..score_str(hiscore),90,1,C_GRY)
 -- lives
 for i=1,player.lives do hud_pset(RX0-12+i*2,RZ,C_BLU) end
 -- bombs
 for i=1,player.bombs do hud_pset(RX1+4+i*2,RZ,C_YEL) end
 -- shield pips
 for i=1,SHIELD_MAX do
  hud_pset(RX0-12+i*2,RZ+2,(i<=player.shield) and C_GRN or C_DGRY)
 end
 hud_print("l"..nstr(level_no).." w"..nstr(min(wave_no,#level.waves)),2,54,level.cols[5])
 draw_radar()
 draw_banner()
 popups_draw()
end

-- little ship glyph used on menus --------------------------------------------
local function menu_ship(x,y,z)
 boxfill(x-2,y-1,z,x+2,y+1,z,C_BLU)
 boxfill(x-1,y,z-1,x+1,y,z-1,C_WHT)
 vset(x+3,y,z,C_YEL)
 vset(x,y,z-2,(frame%20<10) and C_GRN or C_BLU)
end

-- title screen -----------------------------------------------------------------
function title_draw()
 -- starfield
 for d in all(skydots) do
  vset((d.x+flr(frame/4))%128,d.y,d.z,C_WHT)
 end
 boxfill(0,0,58,127,127,63,C_DGRN)
 boxfill(0,0,58,127,127,58,C_GRN)
 hud_print("v o x e l",44,10,C_GRY)
 hud_print("d e f e n d e r",32,18,(frame%30<15) and C_YEL or C_ORG)
 -- drifting ship with rainbow trail
 local mx=20+(frame%176)
 if mx<128 then
  menu_ship(mx,70,34)
  fx_trail(wrapx(cam_x+mx-4),70,GROUND_Z-34,true)
 end
 if frame%40<28 then hud_print("press x to start",34,36,C_WHT) end
 hud_print("hi "..score_str(hiscore),50,46,C_GRY)
end

-- level select --------------------------------------------------------------------
sel=1
function select_draw()
 boxfill(0,0,58,127,127,63,C_DBLU)
 hud_print("select level",40,2,C_YEL)
 for i=1,10 do
  local col=(i>unlocked) and C_DGRY or C_WHT
  if i==sel then col=(frame%16<8) and C_YEL or C_ORG end
  local x=(i<=5) and 8 or 68
  local z=8+((i-1)%5)*8
  local nm=(i>unlocked) and "locked" or LEVELS[i].name
  hud_print(nstr(i).." "..nm,x,z,col)
 end
 hud_print("x-go  hold o+x-title",24,52,C_GRY)
end

function select_update()
 if btnp8(B_U) and sel>1 then sel=sel-1 sfx_safe("ui") end
 if btnp8(B_D) and sel<10 then sel=sel+1 sfx_safe("ui") end
 if btnp8(B_L) and sel>5 then sel=sel-5 sfx_safe("ui") end
 if btnp8(B_R) and sel<=5 then sel=min(sel+5,10) sfx_safe("ui") end
 if btnp8(B_FIRE) then
  if btnh(B_BOMB) then
   mode="title"
  elseif sel<=unlocked then
   start_run(sel) sfx_safe("ui")
  else
   sfx_safe("hurt")
  end
 end
end

-- level clear tally ------------------------------------------------------------------
function clear_draw()
 world_draw()
 particles_draw()
 boxfill(20,0,14,108,2,40,C_BLK)
 hud_line(20,14,108,14,C_YEL)
 hud_print("level "..nstr(level_no).." clear!",34,18,(frame%20<10) and C_YEL or C_GRN)
 local surv=colonists_alive()
 hud_print("colonists x"..nstr(surv).."  +"..nstr(surv*PTS.survive).."0",28,26,C_GRN)
 hud_print("rank "..clear_rank,54,32,C_PNK)
 if clear_t>60 and frame%30<20 then
  hud_print(level_no<10 and "press x" or "press x !",50,38,C_WHT)
 end
end

-- game over / victory -------------------------------------------------------------------
function over_draw()
 world_draw()
 particles_draw()
 boxfill(20,0,14,108,2,40,C_BLK)
 hud_print("game over",46,20,(frame%20<10) and C_RED or C_ORG)
 hud_print("score "..score_str(score),40,28,C_WHT)
 if score>=hiscore and score>0 then hud_print("new best!",46,34,C_YEL) end
 if frame%30<20 then hud_print("press x",50,40,C_GRY) end
end

function win_draw()
 for d in all(skydots) do
  vset((d.x+flr(frame/3))%128,d.y,d.z,C_WHT)
 end
 boxfill(0,0,58,127,127,63,C_DGRN)
 if frame%4==0 then
  fx_confetti(wrapx(cam_x+rnd(128)),20+rnd(80),20+rnd(20))
 end
 particles_draw()
 hud_print("the overmind falls!",26,10,(frame%16<8) and C_GRN or C_YEL)
 hud_print("colony saved",40,18,C_WHT)
 hud_print("score "..score_str(score),40,28,C_YEL)
 hud_print("thank you, ranger",32,38,C_PNK)
 if frame%30<20 then hud_print("press x",50,50,C_GRY) end
end
-- voxel defender : 09_main
-- game states, wave director, scoring, collisions, _init/_update/_draw

frame=0 cam_x=0 shake=0 flash_t=0
score=0 hiscore=0 unlocked=1
mode="title"
level_no=1 level=LEVELS[1]
wave_no=1 ws="intro" ws_t=0 wave_t=0
hostile=false boss_done=false
boss_dying=nil boss_die_t=0 boss_die_x=64 boss_die_y=64 boss_die_alt=24
clear_t=0 clear_rank="c" lives_start=START_LIVES

-- scoring ---------------------------------------------------------------
function award(units,x,y,alt)
 local prev=score
 score=min(score+units,32000)
 if x then popup(x,y,alt,nstr(units).."0",C_YEL) end
 if flr(score/EXTRA_LIFE_EVERY)>flr(prev/EXTRA_LIFE_EVERY) then
  player.lives=player.lives+1
  popup(player.x,player.y,player.alt+6,"1up!",C_GRN)
  sfx_safe("1up")
 end
end

-- hostility: all colonists lost -> every lander mutates ------------------
function check_hostile()
 if hostile then return end
 if colonists_alive()>0 then return end
 hostile=true
 for e in all(enemies) do
  if e.kind=="lander" then
   e.kind="mutant" e.state="hunt"
   if e.victim then e.victim.claimed=nil e.victim=nil end
   fx_explosion(e.x,e.y,e.alt,8,{C_GRN,C_PNK},false)
  end
 end
 set_banner("!! hostile !!",90,C_RED)
 sfx_safe("alarm")
end

-- level flow ---------------------------------------------------------------
local function level_music()
 local n=1
 if level_no>4 then n=2 end
 if level_no>7 then n=3 end
 music_safe("music"..nstr(n),1)
end

function start_level(n)
 level_no=n level=LEVELS[n]
 particles_init() entities_init() enemies_init()
 pads_init(3)
 colonists_init(level.colonists)
 player.x=64 player.y=64 player.dx=0 player.dy=0
 player.shield=SHIELD_MAX player.dead_t=0 player.invuln=INVULN_T
 lives_start=player.lives
 world_init()
 cam_x=0 shake=0 flash_t=0
 wave_no=1 ws="intro" ws_t=0 wave_t=0
 hostile=false boss_done=false boss_dying=nil
 mode="play"
 set_banner(level.name,90,level.cols[5])
 level_music()
end

function start_run(n)
 score=0
 player_init()
 start_level(n)
end

local function next_level()
 player.bombs=min(player.bombs+1,6) -- small refill between levels
 start_level(level_no+1)
end

local function level_clear()
 local surv=colonists_alive()
 score=min(score+surv*PTS.survive,32000)
 local ratio=surv/level.colonists
 local deaths=max(0,lives_start-player.lives)
 if ratio>=0.99 and deaths==0 then clear_rank="s"
 elseif ratio>=0.75 then clear_rank="a"
 elseif ratio>=0.5 then clear_rank="b"
 else clear_rank="c" end
 unlocked=max(unlocked,min(level_no+1,10))
 if score>hiscore then hiscore=score end
 mode="clear" clear_t=0
 sfx_safe("clear")
 music_safe("jingle")
end

-- wave director --------------------------------------------------------------
local function wave_update()
 if ws=="intro" then
  ws_t=ws_t+1
  if ws_t==1 then
   set_banner("wave "..nstr(wave_no).."/"..nstr(#level.waves),60,C_YEL)
  end
  if ws_t>=45 then
   spawn_wave(level.waves[wave_no])
   ws="fight" wave_t=0
  end
 elseif ws=="boss_intro" then
  ws_t=ws_t+1
  if ws_t==1 then
   set_banner("!! warning !!",90,C_RED)
   sfx_safe("alarm")
  end
  if ws_t>=90 then
   espawn(level.boss,wrapx(player.x+WRAP/2),64,26)
   ws="fight" wave_t=0
  end
 elseif ws=="fight" then
  wave_t=wave_t+1
  -- anti-camping baiters from level 4 onward
  if level_no>=4 and wave_t>BAITER_AFTER
     and (wave_t-BAITER_AFTER)%BAITER_EVERY==0
     and enemies_count()<EMAX then
   espawn("baiter",wrapx(player.x+WRAP/2),player.y,20)
   sfx_safe("alarm")
  end
  -- boss death sequence: rolling multi-stage explosions
  if boss_dying then
   boss_die_t=boss_die_t+1
   if boss_die_t%6==0 then
    fx_explosion(wrapx(boss_die_x+rnd(24)-12),
                 boss_die_y+rnd(16)-8, boss_die_alt+rnd(10)-5,
                 12,{C_WHT,C_YEL,C_ORG,C_RED},true)
    sfx_safe("boom")
   end
   if boss_die_t>=70 then
    boss_dying=nil boss_done=true
    fx_smartbomb(boss_die_x,boss_die_y,boss_die_alt)
   end
  elseif #enemies==0 then
   if wave_no<#level.waves then
    wave_no=wave_no+1 ws="intro" ws_t=0
   elseif level.boss and not boss_done then
    ws="boss_intro" ws_t=0
   else
    level_clear()
   end
  end
 end
end

-- player shots vs enemies -------------------------------------------------------
local function shot_collisions()
 for i=#shots,1,-1 do
  local s=shots[i]
  local hit=false
  for e in all(enemies) do
   if hit then break end
   for hb in all(enemy_hitboxes(e)) do
    if abs(wdelta(s.x,hb.x))<hb.rad+1
       and abs(s.y-hb.y)<hb.rad+1
       and abs(s.alt-hb.alt)<hb.rad+2 then
     del(shots,s)
     enemy_damage(e,hb.part)
     hit=true
     break
    end
   end
  end
  if not hit then
   for m in all(mines) do
    if abs(wdelta(s.x,m.x))<3 and abs(s.y-m.y)<3
       and abs(s.alt-m.alt)<4 then
     del(shots,s)
     fx_explosion(m.x,m.y,m.alt,8,{C_YEL,C_ORG},false)
     award(PTS.mine,m.x,m.y,m.alt)
     del(mines,m)
     sfx_safe("boom")
     break
    end
   end
  end
 end
end

-- camera with look-ahead ------------------------------------------------------------
local function camera_update()
 local look=cos(player.facing)*26
 local target=wrapx(player.x-64+look)
 cam_x=wrapx(cam_x+wdelta(cam_x,target)*0.12)
end

-- callbacks -------------------------------------------------------------------------
function _init()
 particles_init()
 entities_init()
 enemies_init()
 player_init()
 world_init()
 music_safe("title")
end

function _update()
 frame=frame+1
 if frame>30000 then frame=0 end
 poll_buttons()
 banner_update()
 shake=max(0,shake-1)
 if flash_t>0 then flash_t=flash_t-1 end

 if mode=="title" then
  particles_update()
  if btnp8(B_FIRE) then mode="select" sfx_safe("ui") end

 elseif mode=="select" then
  select_update()

 elseif mode=="play" then
  player_update()
  enemies_update()
  shots_update() eshots_update() mines_update()
  colonists_update()
  world_update()
  particles_update() popups_update()
  shot_collisions()
  wave_update()
  camera_update()
  if player.lives<0 and player.dead_t<=0 then
   if score>hiscore then hiscore=score end
   mode="over"
   music_safe("gameover")
  end

 elseif mode=="clear" then
  clear_t=clear_t+1
  particles_update() popups_update()
  if clear_t>60 and btnp8(B_FIRE) then
   if level_no<10 then
    next_level()
   else
    mode="win"
    music_safe("victory")
   end
  end

 elseif mode=="over" then
  particles_update()
  if btnp8(B_FIRE) then
   mode="title"
   music_safe("title")
  end

 elseif mode=="win" then
  particles_update()
  if btnp8(B_FIRE) then
   mode="title"
   music_safe("title")
  end
 end
end

function _draw()
 clv()
 -- screen shake: jitter the camera for this frame only
 local realcam=cam_x
 if shake>0 then cam_x=wrapx(cam_x+rnd(shake)-shake/2) end

 if mode=="title" then
  title_draw()
  particles_draw()
 elseif mode=="select" then
  select_draw()
 elseif mode=="play" then
  world_draw()
  mines_draw()
  colonists_draw()
  enemies_draw()
  eshots_draw()
  shots_draw()
  player_draw()
  particles_draw()
  hud_draw()
  if flash_t>0 then
   boxfill(0,0,0,127,127,GROUND_Z+4,C_WHT)
  end
 elseif mode=="clear" then
  clear_draw()
 elseif mode=="over" then
  over_draw()
 elseif mode=="win" then
  win_draw()
 end

 cam_x=realcam
end
