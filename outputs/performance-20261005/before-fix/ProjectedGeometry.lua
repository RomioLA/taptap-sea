-- Project world geometry instead of drawing screen-space circles/radii.
-- Clip in the water plane before projection so near-plane crossings stay finite.
local Config = require("Ocean.Config")
local Projection = require("Ocean.Projection")
local Geometry = {}

local function color(value)
    return nvgRGBA(value[1], value[2], value[3], value[4] or 255)
end

local function planes(movement, altitude, padding)
    -- Screen-X boundaries still map to straight sides in the water plane.
    -- Extend only for the height bound; the surface visibility test clips the
    -- remaining silhouette against intervening water.
    local extension = Projection.VisibleDepth(movement, altitude or 0) - Config.camera.farDepth
    local polygon = Projection.ViewPolygon(movement, padding, extension)
    local result = {}
    for index, point in ipairs(polygon) do
        local nextPoint = polygon[index % #polygon + 1]
        local dx, dy = nextPoint.x - point.x, nextPoint.y - point.y
        result[#result + 1] = { a = -dy, b = dx, c = dy * point.x - dx * point.y }
    end
    return result
end

local function signed(plane, point)
    return plane.a * point.x + plane.b * point.y + plane.c
end

local function between(from, to, fraction)
    return { x = from.x + (to.x - from.x) * fraction,
        y = from.y + (to.y - from.y) * fraction,
        altitude = (from.altitude or 0) + ((to.altitude or 0) - (from.altitude or 0)) * fraction }
end

local function clipPlane(input, signedDistance, crossing)
    local output = {}
    if #input == 0 then return output end
    local previous = input[#input]
    local previousDistance = signedDistance(previous)
    for _, point in ipairs(input) do
        local distance = signedDistance(point)
        if (distance >= 0) ~= (previousDistance >= 0) then
            output[#output + 1] = crossing(previous, point, previousDistance, distance)
        end
        if distance >= 0 then output[#output + 1] = point end
        previous, previousDistance = point, distance
    end
    return output
end

local function sampled(points, closed, step)
    local output = {}
    for index = 1, closed and #points or #points - 1 do
        local a, b = points[index], points[index % #points + 1]
        local count = math.max(1, math.ceil(math.sqrt((b.x-a.x)^2 + (b.y-a.y)^2) / step))
        for sample = 0, count - 1 do output[#output + 1] = between(a, b, sample / count) end
    end
    if not closed and #points > 0 then output[#output + 1] = points[#points] end
    return output
end

local function root(from, to, signedDistance)
    local low, high = 0, 1
    local fromInside = signedDistance(from) >= 0
    for _ = 1, 40 do
        local middle = (low + high) * 0.5
        if (signedDistance(between(from, to, middle)) >= 0) == fromInside then low = middle else high = middle end
    end
    local point = between(from, to, (low + high) * 0.5)
    point.occlusionEdge = true
    return point
end

function Geometry.ClipPolygon(movement, points, altitude, padding)
    local clipped, maxHeight = {}, altitude or 0
    for _, point in ipairs(points) do
        local height = altitude or point.altitude or 0
        maxHeight = math.max(maxHeight, height)
        clipped[#clipped + 1] = { x = point.x, y = point.y, altitude = height }
    end
    for _, plane in ipairs(planes(movement, maxHeight, padding)) do
        local input = clipped
        clipped = {}
        if #input == 0 then break end
        local previous = input[#input]
        local previousDistance = signed(plane, previous)
        for _, point in ipairs(input) do
            local distance = signed(plane, point)
            if (distance >= 0) ~= (previousDistance >= 0) then
                clipped[#clipped + 1] = between(previous, point,
                    previousDistance / (previousDistance - distance))
            end
            if distance >= 0 then clipped[#clipped + 1] = point end
            previous, previousDistance = point, distance
        end
    end
    if maxHeight > 0 and #clipped > 0 then
        clipped = sampled(clipped, true, 0.5)
        local function visible(p) return Projection.Visibility(movement, p, p.altitude) end
        clipped = clipPlane(clipped, visible, function(a, b) return root(a, b, visible) end)
    end
    return clipped
end

function Geometry.ClipLine(movement, from, to, altitude)
    local lo, hi = 0, 1
    for _, plane in ipairs(planes(movement, altitude or math.max(from.altitude or 0, to.altitude or 0))) do
        local a, b = signed(plane, from), signed(plane, to)
        if a < 0 and b < 0 then return end
        if (a >= 0) ~= (b >= 0) then
            local fraction = a / (a - b)
            if a < 0 then lo = math.max(lo, fraction) else hi = math.min(hi, fraction) end
        end
    end
    if lo > hi then return end
    return between(from, to, lo), between(from, to, hi)
end

-- Project every edge, including a newly clipped shore/hill boundary, along the
-- actual horizon curve instead of connecting its endpoints with a chord.
function Geometry.ProjectPolygon(movement, points, altitude, padding)
    local clipped = Geometry.ClipPolygon(movement, points, altitude, padding)
    local output = {}
    if #clipped < 3 then return output end
    for index, a in ipairs(clipped) do
        local b = clipped[index % #clipped + 1]
        local ax, ay = Projection.Project(movement, a, a.altitude)
        local bx, by = Projection.Project(movement, b, b.altitude)
        if not ax or not bx then return {} end
        local boundary = (a.occlusionEdge and b.occlusionEdge)
            or ((a.altitude or 0)==0 and (b.altitude or 0)==0
                and math.abs(a.y-movement.camera.y-Config.camera.farDepth) < 1e-7
                and math.abs(b.y-movement.camera.y-Config.camera.farDepth) < 1e-7)
        local count = math.max(1, math.ceil(math.sqrt((bx-ax)^2+(by-ay)^2)/6),
            math.ceil(math.sqrt((b.x-a.x)^2+(b.y-a.y)^2)/0.5))
        for sample = 0, count - 1 do
            local p = between(a, b, sample/count)
            local x, y, scale = Projection.Project(movement, p, p.altitude)
            if boundary then y = Projection.Horizon(movement, x) end
            output[#output + 1] = { x=x, y=y, scale=scale }
        end
    end
    return output
end

function Geometry.FillScreenPolygon(ctx, points, tint)
    if #points < 3 then return false end
    nvgBeginPath(ctx)
    for index, p in ipairs(points) do
        if index == 1 then nvgMoveTo(ctx,p.x,p.y) else nvgLineTo(ctx,p.x,p.y) end
    end
    nvgClosePath(ctx)
    nvgFillColor(ctx,tint)
    nvgFill(ctx)
    return true
end

-- side=1 is water, side=-1 is exposed far-side height. Used on stroke ribbons
-- too, so a minimum-width stroke cannot leak across the curved sea/sky edge.
function Geometry.ClipScreenPolygon(movement, points, side)
    local function signedDistance(p) return side * (p.y-Projection.Horizon(movement,p.x)) end
    local dense = sampled(points,true,4)
    local clipped = clipPlane(dense,signedDistance,function(a,b) return root(a,b,signedDistance) end)
    local output = {}
    for index, a in ipairs(clipped) do
        output[#output+1] = a
        local b = clipped[index % #clipped+1]
        if a.occlusionEdge and b.occlusionEdge then
            local count=math.max(1,math.ceil(math.abs(b.x-a.x)/4))
            for sample=1,count-1 do
                local x=a.x+(b.x-a.x)*sample/count
                output[#output+1]={x=x,y=Projection.Horizon(movement,x)}
            end
        end
    end
    return output
end

local function screenRibbon(movement,a,b,width,side)
    local dx,dy=b.x-a.x,b.y-a.y
    local length=math.sqrt(dx*dx+dy*dy)
    if length < 1e-9 then return {} end
    local nx,ny=-dy/length*width*.5,dx/length*width*.5
    ---@type table[]
    local ribbon={{x=a.x+nx,y=a.y+ny},{x=b.x+nx,y=b.y+ny},
        {x=b.x-nx,y=b.y-ny},{x=a.x-nx,y=a.y-ny}}
    if side then ribbon=Geometry.ClipScreenPolygon(movement,ribbon,side) end
    return ribbon
end

function Geometry.StrokeScreenLine(ctx,movement,a,b,tint,width,side)
    return Geometry.FillScreenPolygon(ctx,screenRibbon(movement,a,b,width,side),tint)
end

function Geometry.StrokeWorldLine(ctx,movement,from,to,tint,width,altitude)
    local a,b=Geometry.ClipLine(movement,from,to,altitude)
    if not a then return false end
    if altitude then a.altitude,b.altitude=altitude,altitude end
    local ax,ay=Projection.Project(movement,a,a.altitude)
    local bx,by=Projection.Project(movement,b,b.altitude)
    if not ax or not bx then return false end
    local worldLength=math.sqrt((b.x-a.x)^2+(b.y-a.y)^2)
    local count=math.max(1,math.ceil(worldLength/.75),math.ceil(math.sqrt((bx-ax)^2+(by-ay)^2)/8))
    local samples=sampled({a,b},false,worldLength/count+1e-12)
    local points={samples[1]}
    local tangent=movement.camera.y+Config.camera.farDepth
    for index=2,#samples do
        local p,q=samples[index-1],samples[index]
        if (p.y<tangent and q.y>tangent) or (p.y>tangent and q.y<tangent) then
            points[#points+1]=between(p,q,(tangent-p.y)/(q.y-p.y))
        end
        points[#points+1]=q
    end
    local visible=false
    for index=1,#points-1 do
        local p,q=points[index],points[index+1]
        local function clearance(v)return Projection.Visibility(movement,v,v.altitude)end
        local cp,cq=clearance(p),clearance(q)
        if cp>=0 or cq>=0 then
            if cp<0 then p=root(p,q,clearance) elseif cq<0 then q=root(p,q,clearance) end
            local px,py=Projection.Project(movement,p,p.altitude)
            local qx,qy=Projection.Project(movement,q,q.altitude)
            local side
            if (p.altitude or 0)==0 and (q.altitude or 0)==0 then side=1
            elseif math.min(p.y,q.y)>=tangent-1e-9 then side=-1 end
            if px and qx then
                local ribbon=screenRibbon(movement,{x=px,y=py},{x=qx,y=qy},width or 1,side)
                if #ribbon>=3 then
                    if not visible then nvgBeginPath(ctx);visible=true end
                    for vertexIndex,vertex in ipairs(ribbon) do
                        if vertexIndex==1 then nvgMoveTo(ctx,vertex.x,vertex.y)
                        else nvgLineTo(ctx,vertex.x,vertex.y) end
                    end
                    nvgClosePath(ctx)
                end
            end
        end
    end
    if visible then nvgFillColor(ctx,tint);nvgFill(ctx) end
    return visible
end

function Geometry.SampleCircle(center, radius, segments)
    local points = {}
    for index = 0, (segments or Config.visual.projection.circleSegments) - 1 do
        local angle = index * math.pi * 2 / (segments or Config.visual.projection.circleSegments)
        points[#points + 1] = { x = center.x + radius * math.cos(angle),
            y = center.y + radius * math.sin(angle) }
    end
    return points
end

function Geometry.SampleSector(center, radius, heading, halfAngle, segments)
    local count = segments or Config.visual.projection.sectorSegments
    local points = { { x = center.x, y = center.y } }
    for index = 0, count do
        local angle = heading - halfAngle + halfAngle * 2 * index / count
        points[#points + 1] = { x = center.x + radius * math.cos(angle),
            y = center.y + radius * math.sin(angle) }
    end
    return points
end

function Geometry.WorldPolygon(ctx, movement, points, fillColor, strokeColor, strokeWidth, altitude)
    if fillColor then
        local clipped = Geometry.ProjectPolygon(movement, points, altitude)
        if #clipped >= 3 then
            nvgBeginPath(ctx)
            for index, point in ipairs(clipped) do
                local x, y = point.x, point.y
                if not x then return end
                if index == 1 then nvgMoveTo(ctx, x, y) else nvgLineTo(ctx, x, y) end
            end
            nvgClosePath(ctx)
            nvgFillColor(ctx, color(fillColor))
            nvgFill(ctx)
        end
    end
    if strokeColor then
        for index, point in ipairs(points) do
            Geometry.StrokeWorldLine(ctx,movement,point,points[index % #points+1],color(strokeColor),strokeWidth,altitude)
        end
    end
end

function Geometry.WorldCircle(ctx, movement, center, radius, fillColor, strokeColor, strokeWidth, altitude)
    return Geometry.WorldPolygon(ctx, movement, Geometry.SampleCircle(center, radius),
        fillColor, strokeColor, strokeWidth, altitude)
end

function Geometry.WorldSector(ctx, movement, center, radius, heading, halfAngle, fillColor, strokeColor, strokeWidth)
    return Geometry.WorldPolygon(ctx, movement, Geometry.SampleSector(center, radius, heading, halfAngle),
        fillColor, strokeColor, strokeWidth)
end

function Geometry.WorldLine(ctx, movement, from, to, strokeColor, strokeWidth, altitude)
    return Geometry.StrokeWorldLine(ctx,movement,from,to,color(strokeColor),strokeWidth,altitude)
end

-- An explicit drawing adapter for the existing local vector silhouettes. It
-- records their meter-space paths, then projects/clips those same paths. Native
-- NanoVG globals are never replaced and no entity or simulation state is copied.
function Geometry.ArtAPI(ctx, movement, origin, altitude)
    local api, stack, paths = {}, {}, {}
    ---@type number[]
    local matrix = {1,0,0,1,0,0}
    local fillTint, strokeTint = nvgRGBA(255,255,255,255), nvgRGBA(255,255,255,255)
    local strokeWidth = 1
    local function point(x,y)
        return {x=origin.x+matrix[1]*x+matrix[3]*y+matrix[5],
            y=origin.y-matrix[2]*x-matrix[4]*y-matrix[6],altitude=altitude or 0}
    end
    local function multiply(a,b,c,d,e,f)
        local m=matrix
        matrix={m[1]*a+m[3]*b,m[2]*a+m[4]*b,m[1]*c+m[3]*d,m[2]*c+m[4]*d,
            m[1]*e+m[3]*f+m[5],m[2]*e+m[4]*f+m[6]}
    end
    function api.nvgSave()
        stack[#stack+1]={matrix=matrix,fill=fillTint,stroke=strokeTint,width=strokeWidth}
    end
    function api.nvgRestore()
        local state=assert(table.remove(stack),"unbalanced local vector art")
        matrix,fillTint,strokeTint,strokeWidth=state.matrix,state.fill,state.stroke,state.width
    end
    function api.nvgTranslate(_,x,y) multiply(1,0,0,1,x,y) end
    function api.nvgScale(_,x,y) multiply(x,0,0,y,0,0) end
    function api.nvgRotate(_,angle)
        local c,s=math.cos(angle),math.sin(angle)
        multiply(c,s,-s,c,0,0)
    end
    function api.nvgBeginPath() paths={} end
    function api.nvgMoveTo(_,x,y) paths[#paths+1]={point(x,y)} end
    function api.nvgLineTo(_,x,y)
        local path=paths[#paths]
        if not path then api.nvgMoveTo(nil,x,y) else path[#path+1]=point(x,y) end
    end
    function api.nvgQuadTo(_,cx,cy,x,y)
        local path=paths[#paths]
        if not path then return end
        local a,b,c=path[#path],point(cx,cy),point(x,y)
        for index=1,16 do
            local t=index/16;local u=1-t
            path[#path+1]={x=u*u*a.x+2*u*t*b.x+t*t*c.x,
                y=u*u*a.y+2*u*t*b.y+t*t*c.y,altitude=altitude or 0}
        end
    end
    function api.nvgClosePath()
        local path=paths[#paths]
        if path then path.closed=true end
    end
    function api.nvgEllipse(_,x,y,rx,ry)
        local path={closed=true}
        for index=0,47 do
            local angle=index*math.pi*2/48
            path[#path+1]=point(x+math.cos(angle)*rx,y+math.sin(angle)*ry)
        end
        paths[#paths+1]=path
    end
    function api.nvgFillColor(_,tint) fillTint=tint end
    function api.nvgStrokeColor(_,tint) strokeTint=tint end
    function api.nvgStrokeWidth(_,width) strokeWidth=width end
    function api.nvgFill()
        for _,path in ipairs(paths) do
            Geometry.FillScreenPolygon(ctx,Geometry.ProjectPolygon(movement,path),fillTint)
        end
    end
    function api.nvgStroke()
        local norm=math.sqrt(matrix[1]^2+matrix[2]^2)
        local _,_,scale=Projection.Project(movement,origin,altitude)
        local width=strokeWidth*(math.abs(norm-1)<1e-9 and 1 or norm*(scale or 1))
        for _,path in ipairs(paths) do
            for index=1,(path.closed and #path or #path-1) do
                Geometry.StrokeWorldLine(ctx,movement,path[index],path[index % #path+1],strokeTint,width)
            end
        end
    end
    function api.Fill(_,tint)
        api.nvgFillColor(nil,color(tint));api.nvgFill()
    end
    function api.Ellipse(_,x,y,rx,ry,tint)
        api.nvgBeginPath();api.nvgEllipse(nil,x,y,rx,ry);api.Fill(nil,tint)
    end
    function api.Stroke(_,tint,width)
        api.nvgStrokeColor(nil,color(tint));api.nvgStrokeWidth(nil,width);api.nvgStroke()
    end
    return api
end

return Geometry
