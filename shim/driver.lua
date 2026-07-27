-- driver.lua : deterministic scripted run  (voxbox phase 0)
--
-- The input schedule is a pure function of the frame number, so every host
-- replays exactly the same session: title -> select -> level 1, then fly
-- right + fire, smart bomb every 97 frames, warp dash every 450.
-- The cart edge-detects buttons itself (poll_buttons), so single-frame
-- presses at f=10/20 register as menu confirms.

function keys_for(f)
 if f==10 or f==20 then return {4} end        -- X: title->select->play
 if f<30 then return nil end                  -- let menus settle
 if f%450==0 then return {3,5} end            -- warp dash: hold DOWN + O
 if f%97==0 then return {1,4,5} end           -- smart bomb mid-flight
 return {1,4}                                 -- fly right + fire
end

local function release_all()
 for i=0,5 do btn_state[i]=0 end
end

function step_frame(f)
 release_all()
 local keys=keys_for(f)
 if keys then for i=1,#keys do btn_state[keys[i]]=1 end end
 trace_mark("F "..f)
 _tick()          -- advances btnp edge state + time(); emits no trace output
 _update()
 _draw()
end

function run_frames(a,b)
 for f=a,b do step_frame(f) end
end
