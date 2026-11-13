-- Beamer owns frame identity and cross-overlay geometry; the engine stays generic.
local M = {}
local Serial = require('flora.serial')
local Settings = require('flora.settings')
-- These keys belong to the Beamer adapter, not to the botanical engine.
Settings.define('growth', function(v)
  if v=='off' or v=='overlays' or v=='timed' then return v end
  return nil, 'growth must be off, overlays or timed'
end)
Settings.define('growth duration', function(v)
  local n=tonumber(v)
  if n and n>0 and n<math.huge then return n end
  return nil, 'growth duration must be positive and finite (seconds)'
end)
Settings.define('growth fps', function(v)
  local n=tonumber(v)
  if n and n>=1 and n<=60 and n%1==0 then return n end
  return nil, 'growth fps must be an integer from 1 to 60'
end)
local setting_fields={'layout','mix','ornaments','palette','spin','tune','header','doc_seed','reserve',
  'gilt','gilt_dpi','gilt_env','gilt_look','backdrop'}
local growth_defaults={growth='off', ['growth duration']=8, ['growth fps']=20}

local function copy(t)
  if type(t) ~= 'table' then return t end
  local out = {}; for k,v in pairs(t) do out[k] = copy(v) end; return out
end
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local function unhex(s)
  assert(s:match('^%x*$') and #s % 2 == 0, 'invalid cache signature')
  return (s:gsub('%x%x', function(c) return string.char(tonumber(c,16)) end))
end
local rects = {text=true, title=true}
local maxima = {frametitle_height=true, header_right=true, frametitle=true}
local fields = {lines=true, text=true, title=true, frametitle_height=true,
  header_right=true, frametitle=true, body_top=true}
local function boxunion(a,b)
  if not a then return copy(b) end
  return {x0=math.min(a.x0,b.x0), y0=math.min(a.y0,b.y0),
    x1=math.max(a.x1,b.x1), y1=math.max(a.y1,b.y1)}
end
local function geometry(spec)
  local out={lines={}}
  for k in pairs(fields) do if spec[k] ~= nil then out[k]=copy(spec[k]) end end
  return out
end
local function merge(a,b)
  local out=copy(a or {lines={}})
  local seen={}
  for _,r in ipairs(out.lines) do seen[Serial.encode(r)]=true end
  for _,r in ipairs(b.lines or {}) do
    local key=Serial.encode(r)
    if not seen[key] then out.lines[#out.lines+1]=copy(r); seen[key]=true end
  end
  table.sort(out.lines,function(x,y) return Serial.encode(x)<Serial.encode(y) end)
  for k in pairs(fields) do
    if k ~= 'lines' and b[k] ~= nil then
      if rects[k] then out[k]=boxunion(out[k],b[k])
      elseif k=='frametitle' then out[k]=out[k] or b[k]
      elseif maxima[k] then out[k]=math.max(out[k] or b[k],b[k])
      else out[k]=math.min(out[k] or b[k],b[k]) end
    end
  end
  return out
end

-- Cache is numeric TSV plus an opaque hex signature. Never execute cached code.
local function encode(entries)
  local out={'beamer-floral-cache-2'}
  for id=1,M.count do
    local e=entries[id]
    if e then
      out[#out+1]='S\t'..id..'\t'..hex(e.signature)
      out[#out+1]='O\t'..id..'\t'..e.overlays
      local keys={}; for k in pairs(e.geometry) do keys[#keys+1]=k end; table.sort(keys)
      local function row(k,r)
        out[#out+1]=table.concat({'G',id,k,string.format('%.17g',r.x0),string.format('%.17g',r.y0),
          string.format('%.17g',r.x1),string.format('%.17g',r.y1)},'\t')
      end
      for _,k in ipairs(keys) do
        local v=e.geometry[k]
        if k=='lines' then for _,r in ipairs(v) do row(k,r) end
        elseif rects[k] then row(k,v)
        else out[#out+1]=table.concat({'V',id,k,type(v)=='boolean' and (v and '1' or '0') or string.format('%.17g',v)},'\t') end
      end
    end
  end
  return table.concat(out,'\n')..'\n'
end
local function decode(data)
  assert(data:match('^beamer%-floral%-cache%-2\n'), 'cache version')
  local entries={}
  for line in data:gmatch('[^\n]+') do
    if line ~= 'beamer-floral-cache-2' then
      local p={}; for v in line:gmatch('[^\t]+') do p[#p+1]=v end
      local id=assert(tonumber(p[2])); assert(id>=1 and id%1==0)
      if p[1]=='S' then entries[id]={signature=unhex(p[3]),geometry={lines={}}}
      elseif p[1]=='O' then
        local n=assert(tonumber(p[3])); assert(n>=1 and n%1==0 and n<1e7)
        assert(entries[id]).overlays=n
      else
        local g=assert(entries[id]).geometry; local k=p[3]; assert(fields[k])
        local function number(i) local n=assert(tonumber(p[i])); assert(n==n and math.abs(n)<1e12); return n end
        if p[1]=='G' then
          assert(k=='lines' or rects[k]); local r={x0=number(4),y0=number(5),x1=number(6),y1=number(7)}
          assert(r.x0<=r.x1 and r.y0<=r.y1,'reversed cache rectangle')
          if k=='lines' then g.lines[#g.lines+1]=r else g[k]=r end
        else
          assert(p[1]=='V' and not rects[k] and k~='lines')
          if k=='frametitle' then g[k]=number(4)==1 else g[k]=number(4) end
        end
      end
    end
  end
  for _,e in pairs(entries) do assert(e.overlays, "missing overlay count") end
  return entries
end

function M.init(path)
  M.path=path; M.old=nil; M.previous={}; M.current={}; M.count=0; M.context_key=nil
  M.frame=nil; M.pending=nil; M.active_settings=nil; M.animation=nil
  M.animation_root=path:gsub('%.floral%-cache$','.floral-animation')
  M.animation_manifest={}; M.animation_cache=nil; M.cache_warning=false; M.pdf_actions=nil
  if kpse and kpse.record_input_file then kpse.record_input_file(path) end
  local f=io.open(path,'r')
  if f then
    M.old=f:read('*a'); f:close()
    local ok,result=pcall(decode,M.old)
    if ok then M.previous=result else M.old=nil end
  end
end

function M.context(start,continuation,enabled,plain)
  local key=tostring(start)..':'..tostring(continuation)
  if key ~= M.context_key then
    M.count=M.count+1; M.context_key=key; M.frame=nil; M.animation=nil
    M.enabled=enabled; M.plain=plain
  elseif enabled~=M.enabled then
    tex.error('beamer-floral: floraon/off must not change within one frame')
  end
end

function M.prepare(spec)
  -- Untitled frames still have a running headline; plain frames do not.
  if spec.header=='body' and not M.plain and not spec.frametitle then
    spec.body_top=spec.body_top or spec.text.y1
  end
  local document=Serial.encode(flora.settings)
  local dimensions=Serial.encode({width=spec.width,height=spec.height,text=spec.text,header_y=spec.header_y})
  if not M.frame then
    M.frame={document=document, dimensions=dimensions, input_signature=M.input_signature,
      title_preset=M.page_title,
      pending_signature=Serial.encode(M.pending or false), settings={}}
    for _,k in ipairs(setting_fields) do
      M.frame.settings[k]=copy(spec[k])
    end
    M.frame.growth={}
    local active=M.active_settings or flora.settings
    for k,v in pairs(growth_defaults) do
      M.frame.growth[k]=active[k] or v
    end
    M.frame.seed=flora.seed(spec.doc_seed,M.count)
    M.frame.signature=Serial.encode({settings=M.frame.settings,width=spec.width,height=spec.height,
      text=spec.text,header_y=spec.header_y,input_signature=M.input_signature,growth=M.frame.growth})
  elseif document~=M.frame.document
      or (M.pending and Serial.encode(M.pending or false)~=M.frame.pending_signature)
      or dimensions~=M.frame.dimensions
      or M.input_signature~=M.frame.input_signature
      or Serial.encode(flora.reserve)~=Serial.encode(M.frame.settings.reserve) then
    tex.error('beamer-floral: floral settings and page dimensions must not change within one frame')
  end
  local signature=M.frame.signature
  local observed=geometry(spec)
  local entry=M.current[M.count]
  if not entry then entry={signature=signature,geometry={lines={}},overlays=0}; M.current[M.count]=entry end
  entry.geometry=merge(entry.geometry,observed)
  entry.overlays=entry.overlays+1
  local cached=M.previous[M.count]
  local selected=cached and cached.signature==signature and merge(cached.geometry,observed) or entry.geometry
  for k in pairs(fields) do spec[k]=copy(selected[k]) end
  for _,k in ipairs(setting_fields) do
    spec[k]=copy(M.frame.settings[k])
  end
  spec.seed=M.frame.seed
  -- split parity and any page-dependent composition must stay fixed as well.
  spec.page=M.count
  M.stage=entry.overlays
  M.stages=cached and cached.signature==signature and cached.overlays or M.stage
  -- A changed count is provisional until the next run. Never extrapolate.
  M.stages=math.max(M.stage,M.stages)
end

-- Growth is deliberately lazy: ordinary documents need neither the new
-- engine capability nor animate. The plan lives for one logical frame.
local Cache
local function raster_cache()
  if not Cache then Cache=dofile(kpse.find_file('beamer-floral-cache.lua','tex')) end
  return Cache
end

function M.render_page(spec,a)
  local growth=M.frame.growth
  if growth.growth=='off' or M.handout then return nil end
  if flora.render_page_version~=1 or type(flora.typeset_page)~='function' then
    tex.error('beamer-floral: growth needs tikz-flora with render_page_version=1')
    return nil
  end
  if growth.growth=='timed' and not M.animation_support then
    tex.error('beamer-floral: growth=timed needs \\usepackage{beamer-floral-animation} in the preamble')
    return nil
  end
  local Progression=require('flora.progression')
  if Progression.api_version~=1 then
    tex.error('beamer-floral: unsupported flora.progression API (need version 1)')
    return nil
  end
  local frame=M.frame
  local key=Serial.encode(spec)
  if frame.plan_key~=key then
    frame.plan=Progression.plan(copy(spec)); frame.plan_key=key
    frame.stage_count=nil
  end
  if frame.stage_count~=M.stages then
    frame.levels=Progression.stages(frame.plan,M.stages)
    frame.stage_count=M.stages
  end
  local last=frame.levels[M.stage]
  if growth.growth=='overlays' then return Progression.render(frame.plan,last) end
  local first=M.stage==1 and 0 or frame.levels[M.stage-1]
  local seconds=growth['growth duration']/M.stages
  local samples=seconds*growth['growth fps']
  if seconds==0 or samples>2147483646 or 1/seconds==math.huge then
    tex.error('beamer-floral: growth duration exceeds animation numeric limits')
    return nil
  end
  local steps=math.max(1,math.floor(samples+0.5))
  local raster
  if M.raster_cache then
    raster=raster_cache().collect(M,copy(spec),steps)
    if not raster then
      if os.getenv('FLORAL_ANIMATION_PREPARE')~='1' then
        tex.error('beamer-floral: raster animation cache missing or stale; run python3 tools/build_animation.py for this document, or select [vector]')
        return nil
      end
      if not M.cache_warning then
        tex.sprint('\\PackageWarningNoLine{beamer-floral-animation}{Raster cache missing or stale. Run python3 tools/build_animation.py for this document. Showing static interval endpoints}')
        M.cache_warning=true
      end
      return Progression.render(frame.plan,last)
    end
  end
  M.animation={plan=frame.plan,spec=copy(spec),args=copy(a),first=first,last=last,steps=steps,raster=raster}
  -- N intervals have N+1 samples, including their exact endpoints.
  -- The final frame has no playback dwell; animate stops on that frame.
  tex.sprint(string.format(
    '\\begingroup\\def\\floralanimationlast{%d}\\floralanimationclock\\begin{animateinline}[method=ocg,autoplay,autopause=false,autoresume=false,loop=false,palindrome=false,controls=false,nomouse,poster=last,label=floral-%d-%d]{%.12g}',
    steps,M.count,M.stage,steps/seconds))
  for i=0,steps do
    if i>0 then tex.sprint('\\newframe') end
    tex.sprint(string.format('\\directlua{beamer_floral.paint_animation(%d)}',i))
  end
  tex.sprint('\\end{animateinline}\\endgroup')
  return true
end

-- Overlays of a static frame show the same flora: paint it once as a form
-- and draw that form on each page. Clips and bands are applied per page.
function M.render_static(spec)
  local Paint=require('flora.paint')
  local frame=M.frame
  local key=Serial.encode(spec)
  if frame.static_key~=key then
    local pt=require('flora.compose').page(copy(spec))
    local forms,resources=Paint.forms({{chunks={pt:body()}}},spec.width,spec.height)
    frame.static={pt=pt,forms=forms,resources=resources}
    frame.static_key=key
  end
  local shared=frame.static
  local painter=Paint.new{backend='pdf'}
  painter.defs=shared.pt.defs
  painter.xobjects=shared.forms
  painter.pdf_resources=shared.resources
  painter.coverage=shared.pt.coverage
  painter.count=shared.pt.count
  painter:emit('/'..shared.forms[1].name..' Do')
  return painter
end

function M.paint_animation(i)
  local animation=assert(M.animation,'missing floral animation')
  if animation.raster then
    return raster_cache().typeset(animation,i)
  end
  local t=animation.first+(animation.last-animation.first)*i/animation.steps
  local pt=require('flora.progression').render(animation.plan,t)
  flora.typeset_page(pt,animation.spec,animation.args)
end

function M.note_animation(id)
  if not M.pdf_actions then M.pdf_actions=dofile(kpse.find_file('beamer-floral-pdf.lua','tex')) end
  M.pdf_actions.note(id)
end

function M.finish()
  if M.pdf_actions then M.pdf_actions.finish() end
  if M.animation_support then raster_cache().finish(M) end
  if kpse and kpse.record_output_file then kpse.record_output_file(M.path) end
  local data=encode(M.current)
  if data~=M.old then
    local f=assert(io.open(M.path..'.tmp','w')); f:write(data); f:close()
    assert(os.rename(M.path..'.tmp',M.path))
    tex.sprint('\\PackageWarningNoLine{beamer-floral}{Floral geometry or overlay count changed. Rerun to get stable overlays}')
  end
end

M._merge=merge; M._decode=decode; M._encode=encode
return M
