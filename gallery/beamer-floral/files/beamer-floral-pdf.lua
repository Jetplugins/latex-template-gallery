-- Document-level view preparation; PDF defaults remain the static endpoint.
local M={ids={}}
local function skip(s,i)
  while i<=#s do
    local c=s:sub(i,i)
    if c:match('%s') then i=i+1
    elseif c=='%' then i=(s:find('[\r\n]',i+1) or #s)+1
    else break end
  end
  return i
end
local value
value=function(s,i)
  i=skip(s,i);local c=s:sub(i,i)
  if s:sub(i,i+1)=='<<' then
    local j=i+2
    while true do j=skip(s,j);if s:sub(j,j+1)=='>>' then return j+2 end
      assert(j<=#s,'unterminated PDF dictionary');j=value(s,j) end
  elseif c=='[' then
    local j=i+1
    while true do j=skip(s,j);if s:sub(j,j)==']' then return j+1 end
      assert(j<=#s,'unterminated PDF array');j=value(s,j) end
  elseif c=='(' then
    local j,depth=i+1,1
    while depth>0 do
      assert(j<=#s,'unterminated PDF string');c=s:sub(j,j)
      if c=='\\' then j=j+2
      else if c=='(' then depth=depth+1 elseif c==')' then depth=depth-1 end;j=j+1 end
    end
    return j
  elseif c=='<' then return assert(s:find('>',i+1),'unterminated PDF hex string')+1
  else
    local token=s:sub(i):match(c=='/' and '^/[^%s%(%)<>%[%]{}/%%]*' or '^[^%s%(%)<>%[%]{}/%%]+')
    assert(token and #token>0,'invalid PDF token');local j=i+#token
    if token:match('^[+-]?%d+$') then
      local k=skip(s,j);local generation=s:sub(k):match('^%d+')
      if generation then local r=skip(s,k+#generation)
        if s:sub(r,r)=='R' then return r+1 end
      end
    end
    return j
  end
end
local function field(s,key)
  local i=skip(s,1)
  while i<=#s do
    local ending=value(s,i);local name=s:sub(i,ending-1)
    local start=skip(s,ending);local finish=value(s,start)
    if name==key then return start,finish end
    i=skip(s,finish)
  end
end
local function replace(s,key,replacement)
  local a,b=field(s,key)
  if a then return s:sub(1,a-1)..replacement..s:sub(b) end
  return s..' '..key..' '..replacement
end
local function bytes(key)
  if key:sub(1,1)=='<' then
    local hex=key:sub(2,-2):gsub('%s','');if #hex%2==1 then hex=hex..'0' end
    return (hex:gsub('%x%x',function(h)return string.char(tonumber(h,16)) end))
  end
  assert(key:sub(1,1)=='(','PDF name-tree keys must be strings')
  local map={n='\n',r='\r',t='\t',b='\b',f='\f'}
  return (key:sub(2,-2):gsub('\\(%d%d?%d?)',function(n)return string.char(tonumber(n,8))end)
    :gsub('\\([\r\n]+)',''):gsub('\\(.)',function(c)return map[c] or c end))
end
local function merge_names(names,reference)
  local a,b=field(names,'/JavaScript')
  local tree=a and names:sub(a,b-1) or '<< >>'
  assert(tree:sub(1,2)=='<<','cannot merge an indirect document JavaScript name tree')
  local body=tree:sub(3,-3)
  assert(not field(body,'/Kids'),'cannot merge a branched document JavaScript name tree')
  local x,y=field(body,'/Names');local array=x and body:sub(x,y-1) or '[]'
  assert(array:sub(1,1)=='[','cannot merge an indirect JavaScript names array')
  local entries={};local i=skip(array,2)
  while array:sub(i,i)~=']' do
    local j=value(array,i);local k=skip(array,j);local ending=value(array,k)
    local key=array:sub(i,j-1)
    entries[#entries+1]={key=key,order=bytes(key),action=array:sub(k,ending-1)}
    i=skip(array,ending)
  end
  entries[#entries+1]={key='(beamer-floral-growth)',order='beamer-floral-growth',action=reference}
  table.sort(entries,function(p,q)return p.order<q.order end)
  local out={};for _,entry in ipairs(entries)do out[#out+1]=entry.key..' '..entry.action end
  body=replace(body,'/Names','['..table.concat(out,' ')..']')
  if field(body,'/Limits') then body=replace(body,'/Limits','['..entries[1].key..' '..entries[#entries].key..']') end
  return replace(names,'/JavaScript','<< '..body..' >>')
end
function M.note(id)
  id=assert(tonumber(id));assert(id>=0 and id%1==0);M.ids[id]=true
end
function M.finish()
  local ids={};for id in pairs(M.ids)do ids[#ids+1]=id end;table.sort(ids)
  if #ids==0 then return end
  local flags={};for _,id in ipairs(ids)do flags[#flags+1]='"'..id..'":true' end
  local code='var floralPrepareExcept; (function floralPrepare(doc){var ids={'..table.concat(flags,',')..'};'
    ..'floralPrepareExcept=function(current){var other=doc.getOCGs();if(!other){return;}'
    ..'for(var j=0;j<other.length;j++){var parts=other[j].name.split(".");'
    ..'if(ids[parts[0]]&&parts[0]!==String(current)&&/^[0-9]+$/.test(parts[1])){'
    ..'other[j].state=(parts[1]==="0");}}};'
    ..'var layers=doc.getOCGs();if(!layers){return;}for(var i=0;i<layers.length;i++){'
    ..'var name=layers[i].name.split(".");if(ids[name[0]]&&/^[0-9]+$/.test(name[1])){'
    ..'layers[i].state=(name[1]==="0");}}})(this);'
  local script=pdf.immediateobj('stream',code)
  local action=pdf.immediateobj('<< /S /JavaScript /JS '..script..' 0 R >>')
  pdf.setnames(merge_names(pdf.getnames() or '',action..' 0 R'))
end
M._merge_names=merge_names
return M
