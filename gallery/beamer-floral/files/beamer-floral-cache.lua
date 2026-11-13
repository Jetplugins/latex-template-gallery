-- Raster cache metadata. Files use the engine's plain-data serializer.
local Serial=require('flora.serial')
local C={version=1}
local function read(path)
  local f=io.open(path,'rb'); if not f then return nil end
  local s=f:read('a'); f:close(); return s
end
function C.load(path)
  local s=read(path); if not s then return nil end
  local ok,t=pcall(Serial.decode,s)
  if ok and type(t)=='table' and t.version==C.version then return t end
end
local function write(path,value)
  local data=Serial.encode(value)..'\n'
  if data==read(path) then return end
  local f=assert(io.open(path..'.tmp','w')); f:write(data); f:close()
  assert(os.rename(path..'.tmp',path))
end
local function signature(record)
  local ok,engine=pcall(require,'flora.cache')
  assert(ok and type(engine.key)=='function','raster playback needs the pinned tikz-flora cache API')
  return assert(engine.key({raster_cache_version=C.version,frame=record}),
    'cannot identify engine sources for raster playback')
end
function C.collect(adapter,spec,steps)
  local record={spec=spec,stages=adapter.stages,steps=steps,levels=adapter.frame.levels}
  record.signature=signature(record)
  adapter.animation_manifest[adapter.count]=record
  if not adapter.animation_cache then
    local path=adapter.animation_root..'/index.floral'
    if kpse and kpse.record_input_file then kpse.record_input_file(path) end
    adapter.animation_cache=C.load(path) or {version=C.version,frames={}}
  end
  local cached=(adapter.animation_cache.frames or {})[adapter.count]
  if not cached or cached.signature~=record.signature or cached.steps~=steps
      or cached.stages~=adapter.stages then return nil end
  if type(cached.dpi)~='number' or cached.dpi<36 or cached.dpi>600 then return nil end
  local prefix=adapter.animation_root..'/'..record.signature..'-'..cached.dpi..'/sample-'
  -- Keep playback, interval boundaries and the static poster on the same
  -- rendering path; switching to a heavy vector endpoint can flash in Reader.
  for i=0,steps*adapter.stages do
      local f=io.open(prefix..i..'.png','rb')
      if not f then return nil end
      local signature=f:read(8); f:close()
      if signature~='\137PNG\r\n\26\n' then return nil end
  end
  return {prefix=prefix,steps=steps,stage=adapter.stage}
end
function C.finish(adapter)
  local path=adapter.animation_root..'-manifest'
  if kpse and kpse.record_output_file then kpse.record_output_file(path) end
  write(path,{version=C.version,frames=adapter.animation_manifest})
end
function C.typeset(animation,i)
  local path=animation.raster.prefix..((animation.raster.stage-1)*animation.steps+i)..'.png'
  path=path:gsub('\\','/')
  assert(not path:find('[%%{}\r\n]'),'unsupported TeX characters in animation cache path')
  local pt=require('flora.paint').new({backend='pgf'})
  pt:emit(string.format('\\pgftext[left,bottom,at=\\pgfpointorigin]{\\includegraphics[width=%.8fpt,height=%.8fpt]{\\detokenize{%s}}}',
    animation.spec.width,animation.spec.height,path))
  flora.typeset_page(pt,animation.spec,animation.args)
end
return C
