-- Reusable whole-page growth. Geometry/randomness is consumed only by plan.
local Paint = require('flora.paint')
local G = require('flora.geom')
local M = { api_version = 1 }
local Rec = {}; Rec.__index = Rec
local BP = 72 / 72.27
local function copy(v)
  if type(v) ~= 'table' then return v end
  local t = {}; for k,x in pairs(v) do t[k] = copy(x) end; return t
end
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function checkplan(p) assert(type(p)=='table' and p.api_version==1, 'unsupported progression plan version') end

-- Flatten in page coordinates, including the hero's perspective and frame
-- rotation. The fixed sampling grid measures silhouettes, never wash passes.
local function contours(cmds, pj)
  local polys, p, x, y = {}, nil, 0, 0
  local function add(a,b)
    x,y=a,b; local u,v=a,b; if pj then u,v=pj(a,b) end
    p[#p+1]={u,v}
  end
  for _,c in ipairs(cmds) do
    if c[1]=='m' then p={}; polys[#polys+1]=p; add(c[2],c[3])
    elseif c[1]=='l' then add(c[2],c[3])
    elseif c[1]=='c' then
      local a,b=x,y
      for i=1,8 do local t=i/8; local s=1-t
        add(s^3*a+3*s*s*t*c[2]+3*s*t*t*c[4]+t^3*c[6],s^3*b+3*s*s*t*c[3]+3*s*t*t*c[5]+t^3*c[7])
      end
    elseif c[1]=='o' then
      p={}; polys[#polys+1]=p
      for i=0,31 do local a=i*math.pi/16; add(c[2]+c[4]*math.cos(a),c[3]+c[4]*math.sin(a)) end
    end
  end
  return polys
end
local function inside(polys,x,y)
  local winding=0
  for _,p in ipairs(polys) do
    local a=p[#p]
    for _,b in ipairs(p) do
      if (a[2]<=y and b[2]>y) or (b[2]<=y and a[2]>y) then
        local ix=a[1]+(y-a[2])*(b[1]-a[1])/(b[2]-a[2])
        if ix>x then winding=winding+(b[2]>a[2] and 1 or -1) end
      end
      a=b
    end
  end
  return winding~=0
end
function Rec:allowed(x,y)
  if x<0 or y<0 or x>self.width or y>self.height then return false end
  for _,r in ipairs(self.reserve) do if x>=r[1] and x<=r[3] and y>=r[2] and y<=r[4] then return false end end
  local key=math.floor(y/self.resolution)*self.nx+math.floor(x/self.resolution)
  for _,c in ipairs(self.clips) do
    c.cache=c.cache or {}
    local v=c.cache[key]
    if v==nil then v=inside(c,x,y); c.cache[key]=v end
    if not v then return false end
  end
  return true
end
function Rec:measure(pt,cmds,width)
  if self.suspended or not self.active then return end
  local polys=contours(cmds,pt:_pj()); local step=self.resolution
  local bounds=self.active.bounds or {math.huge,math.huge,-math.huge,-math.huge}
  local pad=(width or 0)/2+2
  for _,poly in ipairs(polys) do for _,q in ipairs(poly) do
    bounds[1]=math.min(bounds[1],q[1]-pad); bounds[2]=math.min(bounds[2],q[2]-pad)
    bounds[3]=math.max(bounds[3],q[1]+pad); bounds[4]=math.max(bounds[4],q[2]+pad)
  end end
  self.active.bounds=bounds
  local cells=self.active.cells
  local function mark(i,j,coverage)
    local x,y=(i+.5)*step,(j+.5)*step
    if self:allowed(x,y) then
      local key=j*self.nx+i
      cells[key]=math.max(cells[key] or 0,coverage or 1)
    end
  end
  if width then
    -- Fine strokes receive a conservative one-cell footprint; filled washes
    -- and their repeated grain share the same cells in a semantic part.
    for _,p in ipairs(polys) do
      for n=2,#p do local a,b=p[n-1],p[n]; local d=G.dist(a,b)
        local count=math.max(1,math.ceil(d/(step*.5)))
        local pad=math.floor(width/(2*step))
        for k=0,count do local t=k/count
          local i,j=math.floor((a[1]+(b[1]-a[1])*t)/step),math.floor((a[2]+(b[2]-a[2])*t)/step)
          for dj=-pad,pad do for di=-pad,pad do mark(i+di,j+dj,math.min(1,width/step)) end end
        end
      end
    end
  else
    local ymin,ymax=math.huge,-math.huge
    for _,p in ipairs(polys) do for _,q in ipairs(p) do ymin=math.min(ymin,q[2]); ymax=math.max(ymax,q[2]) end end
    for j=math.max(0,math.floor(ymin/step)),math.min(self.ny-1,math.floor(ymax/step)) do
      local y=(j+.5)*step; local crosses={}
      for _,p in ipairs(polys) do local a=p[#p]
        for _,b in ipairs(p) do
          if (a[2]<=y and b[2]>y) or (b[2]<=y and a[2]>y) then
            crosses[#crosses+1]={a[1]+(y-a[2])*(b[1]-a[1])/(b[2]-a[2]),b[2]>a[2] and 1 or -1}
          end; a=b
        end
      end
      table.sort(crosses,function(a,b) return a[1]<b[1] end)
      local winding=0; local left
      for _,c in ipairs(crosses) do
        if winding==0 then left=c[1] end
        winding=winding+c[2]
        if winding==0 then
          for i=math.max(0,math.ceil(left/step-.5)),math.min(self.nx-1,math.floor(c[1]/step-.5)) do mark(i,j) end
        end
      end
    end
  end
end
function Rec:part(pt,kind,anchor,birth,duration,fn,stem,support)
  assert(not self.active,'nested progression parts')
  local pj=pt.frame_fn
  local function page(p) if pj then local x,y=pj(p[1],p[2]); return {x,y} end return {p[1],p[2]} end
  local p={kind=kind,anchor=anchor and page(anchor),birth=birth or 0,duration=math.max(1e-9,duration or .15),cells={},chunks={}}
  if support then
    p.token=support.token; p.support_token=support.parent
    if support.parent then
      local t=math.max(0,math.min(1,support.t or 1))
      p.support_source_fraction=t
      p.support_point=page(G.at(support.parent.pts,t))
      p.anchor=p.support_point
    end
  end
  if stem then p.stem={}; for _,q in ipairs(stem) do p.stem[#p.stem+1]=page(q) end end
  self.parts[#self.parts+1]=p; self.events[#self.events+1]=p
  -- Keep the final source silhouette before applying growth transforms.
  -- Otherwise paint hidden by a fixed header/frame clip can be scaled back
  -- into view, especially for a fully clipped part with no sampled anchor.
  local masks={}
  for _,clip in ipairs(self.clips) do masks[#masks+1]=clip.source end
  self.active=p; fn()
  if pt.gilt_pending then require('flora.orn_raster').flush(pt) end
  self.active=nil
  local b=p.bounds
  if not b or b[1]<0 or b[2]<0 or b[3]>self.width or b[4]>self.height then
    masks[#masks+1]=string.format('q 0 0 %.6f %.6f re W n',self.width*BP,self.height*BP)
  end
  for _,r in ipairs(self.reserve) do
    if not b or (b[1]<r[3] and b[3]>r[1] and b[2]<r[4] and b[4]>r[2]) then
      masks[#masks+1]=string.format('q 0 0 %.6f %.6f re %.6f %.6f %.6f %.6f re W* n',
        self.width*BP,self.height*BP,r[1]*BP,r[2]*BP,(r[3]-r[1])*BP,(r[4]-r[2])*BP)
    end
  end
  local chunks={}
  for _,mask in ipairs(masks) do chunks[#chunks+1]=mask end
  for _,chunk in ipairs(p.chunks) do chunks[#chunks+1]=chunk end
  for _ in ipairs(masks) do chunks[#chunks+1]='Q' end
  p.chunks=chunks
  local n,sx,sy=0,0,0
  for key,weight in pairs(p.cells) do n=n+weight; sx=sx+(key%self.nx+.5)*self.resolution*weight; sy=sy+(key//self.nx+.5)*self.resolution*weight end
  p.area=n*self.resolution^2; p.cells=nil
  if not p.anchor then p.anchor=n>0 and {sx/n,sy/n} or {0,0} end
end
-- Alternate part streams for batched pen work, retaining the original final
-- stream byte for byte. The alternate consumes no composition randomness.
function Rec:alternate(pt,fn,canonical)
  self.suspended=true; canonical(); self.suspended=false
  local out,count=pt.out,pt.count; pt.out={}
  local probe=pt.probe; pt.probe=nil
  self.capturing_alternate=true
  fn(); self.capturing_alternate=nil; pt.out=out; pt.count=count; pt.probe=probe
end
function M.attach(pt,spec)
  local r=spec._progression
  if not r then return end
  pt.progression=r
  local emit=pt.emit
  pt.emit=function(p,s)
    emit(p,s)
    if r.suspended then return end
    local list=r.active and r.active.chunks or r.events
    list[#list+1]=s
  end
  for _,name in ipairs({'fill','stroke'}) do
    local original=pt[name]
    pt[name]=function(p,cmds,...)
      local args={...}; local opts=args[name=='stroke' and 4 or 3] or {}
      if opts.many then for _,c in ipairs(cmds) do r:measure(p,c,name=='stroke' and args[2] or nil) end
      else r:measure(p,cmds,name=='stroke' and args[2] or nil) end
      return original(p,cmds,...)
    end
  end
  local begin,finish=pt.clip_begin,pt.clip_end
  pt.clip_begin=function(p,cmds)
    begin(p,cmds)
    if not r.suspended then
      local clip=contours(cmds,p:_pj()); clip.source=p.out[#p.out]
      r.clips[#r.clips+1]=clip
    end
  end
  pt.clip_end=function(p)
    finish(p)
    if not r.suspended then r.clips[#r.clips]=nil end
  end
end
function M.part(pt,kind,anchor,birth,duration,fn,stem,support)
  if pt.progression and not pt.progression.suspended then return pt.progression:part(pt,kind,anchor,birth,duration,fn,stem,support) end
  local result=fn()
  if pt.gilt_pending then require('flora.orn_raster').flush(pt) end
  return result
end
function M.plan(spec,opts)
  opts=opts or {}; local step=opts.resolution or 1
  assert(finite(step) and step>0,'progression resolution must be positive and finite')
  assert(not spec.backend or spec.backend=='pdf','progression requires the PDF backend')
  local s=copy(spec); s.grow=nil; s.backend='pdf'
  local protected=copy(s.reserve or {})
  for _,l in ipairs(s.lines or {s.text}) do protected[#protected+1]={l.x0,l.y0,l.x1,l.y1} end
  local r=setmetatable({width=s.width,height=s.height,reserve=protected,resolution=step,
    nx=math.ceil(s.width/step),ny=math.ceil(s.height/step),parts={},events={},clips={}},Rec)
  s._progression=r
  local pt=require('flora.compose').page(s)
  -- Resolve the construction DAG, independent of paint layer, width bucket
  -- or provisional birth time. A child cannot start until its actual parent
  -- reaches the attachment; resolving recursively propagates that guarantee
  -- all the way to the main stem. Crossing nearby stems are never candidates.
  local tokens={}
  for _,p in ipairs(r.parts) do if p.token then
    assert(not tokens[p.token], 'duplicate growth stem token')
    tokens[p.token]=p
  end end
  local state={}
  local function resolve(p)
    if state[p]==2 then return end
    assert(state[p]~=1,'cyclic growth support graph')
    state[p]=1
    if p.support_token then
      local token,t=p.support_token,p.support_source_fraction
      -- A disabled corner runner still participates in ordinary composition:
      -- its decorations remain, but its invisible span adds no growth wait.
      -- Follow only explicitly omitted construction nodes to a painted ancestor.
      local omitted={}
      while not tokens[token] and token.growth_omitted do
        assert(not omitted[token],'cyclic omitted growth support graph')
        omitted[token]=true
        t=token.growth_t or 1
        token=assert(token.growth_parent,'omitted growth support has no parent')
      end
      local parent=assert(tokens[token],'growth support stem was not painted')
      assert(parent.stem,'growth support is not a stem')
      resolve(parent)
      p.support=parent
      p.support_fraction=G.mapped_fraction(token.pts,parent.stem,t)
      p.birth=math.max(p.birth,parent.birth+parent.duration*p.support_fraction)
    end
    state[p]=2
  end
  for _,p in ipairs(r.parts) do resolve(p) end
  local area=0; local finish=0
  for _,p in ipairs(r.parts) do area=area+p.area; finish=math.max(finish,p.birth+p.duration) end
  local changes={}
  for _,p in ipairs(r.parts) do
    local slope=p.area/p.duration
    changes[p.birth]=(changes[p.birth] or 0)+slope
    local ending=p.birth+p.duration
    changes[ending]=(changes[ending] or 0)-slope
  end
  local keys={}; for u in pairs(changes) do keys[#keys+1]=u end; table.sort(keys)
  local timeline={}; local u0,a0,slope=0,0,0
  for _,u in ipairs(keys) do
    a0=a0+(u-u0)*slope; slope=slope+changes[u]
    timeline[#timeline+1]={u=u,area=a0,slope=slope}; u0=u
  end
  local forms,resources=Paint.forms(r.parts,s.width,s.height)
  return {api_version=1,forms=forms,pdf_resources=resources,parts=r.parts,events=r.events,final=pt,width=s.width,height=s.height,
    area=area,finish=finish,resolution=step,reserve=copy(s.reserve or {}),protected=r.reserve,timeline=timeline}
end
local function progress(p,u) return math.max(0,math.min(1,(u-p.birth)/p.duration)) end
local function time(plan,t)
  if t==0 then return 0 end
  if t==1 then return plan.finish end
  local target=plan.area*t; local timeline=plan.timeline
  local lo,hi=1,#timeline
  while lo<hi do local mid=(lo+hi+1)//2
    if timeline[mid].area<=target then lo=mid else hi=mid-1 end
  end
  local node=timeline[lo]
  return node.u+(target-node.area)/math.max(node.slope,1e-12)
end
function M.render(plan,t)
  checkplan(plan); assert(finite(t) and t>=0 and t<=1,'progression must be finite and between 0 and 1')
  local pt=Paint.new({backend='pdf'}); pt.defs=plan.final.defs; pt.coverage=plan.final.coverage
  local u=time(plan,t)
  -- All stages, including the untouched canonical endpoint, use the same
  -- native frame-Form transport when typeset by LuaTeX.
  pt.xobjects=plan.forms; pt.pdf_resources=plan.pdf_resources; pt.width=plan.width; pt.height=plan.height
  -- Reservation clips stay in page space, outside all organic transforms.
  local exclusions=t==1 and plan.reserve or plan.protected
  for _,r in ipairs(exclusions) do
    pt:emit(string.format('q 0 0 %.6f %.6f re %.6f %.6f %.6f %.6f re W* n',plan.width*BP,plan.height*BP,r[1]*BP,r[2]*BP,(r[3]-r[1])*BP,(r[4]-r[2])*BP))
  end
  if t==1 then
    for _,s in ipairs(plan.final.out) do pt:emit(s) end
    for _ in ipairs(exclusions) do pt:emit('Q') end
    pt.count=plan.final.count
    return pt
  end
  local function paint(part)
    if part.form then pt:emit('/'..part.form..' Do')
    else for _,s in ipairs(part.chunks) do pt:emit(s) end end
  end
  for _,e in ipairs(plan.events) do
    if type(e)=='string' then pt:emit(e)
    else local k=progress(e,u)
      if k>0 then
        pt:emit('q')
        if e.stem and k<1 then
          local total=G.length(e.stem); local shown=total*k; local prefix={e.stem[1]}; local d=0
          for i=2,#e.stem do local a,b=e.stem[i-1],e.stem[i]; local len=G.dist(a,b)
            if d+len>shown then prefix[#prefix+1]=G.mix(a,b,(shown-d)/len); break end
            prefix[#prefix+1]=b; d=d+len
          end
          if #prefix>=2 then pt:clip_begin(G.smooth(G.ribbon(prefix,function() return 12 end),true)) end
          paint(e)
          if #prefix>=2 then pt:clip_end() end
        else
          local scale=math.sqrt(k); local a=e.anchor
          pt:emit(string.format('%.8f 0 0 %.8f %.8f %.8f cm',scale,scale,a[1]*(1-scale)*BP,a[2]*(1-scale)*BP))
          paint(e)
        end
        pt:emit('Q'); pt.count=pt.count+1
      end
    end
  end
  for _ in ipairs(exclusions) do pt:emit('Q') end
  return pt
end
function M.stages(plan,n)
  checkplan(plan)
  assert(finite(n) and n>=1 and n%1==0,'stage count must be a positive integer')
  assert(plan.area>0 and plan.area/n>=plan.resolution^2,
    'progression resolution insufficient for requested stages; reduce stage count or resolution')
  local out={}; local previous
  for k=1,n do
    local t=k/n; local u=time(plan,t); local signature={}
    for _,p in ipairs(plan.parts) do
      if p.area>0 then signature[#signature+1]=string.format('%.6f',progress(p,u)) end
    end
    signature=table.concat(signature,',')
    assert(signature~=previous,'progression resolution insufficient: identical consecutive stages')
    previous=signature; out[k]=t
  end
  return out
end
return M
