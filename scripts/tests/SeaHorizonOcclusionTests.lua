-- Behavioral contracts for the shared surface, height and footprint occlusion.
local Config = require("Ocean.Config")
local Projection = require("Ocean.Projection")
local Geometry = require("Ocean.ProjectedGeometry")
local Presentation = require("Ocean.SeaPresentation")
local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local Tests = {}

local function view(width, height)
    local v={camera={x=17,y=-9},viewportWidth=width or 1920,viewportHeight=height or 1080}
    function v:WorldToScreen(p,altitude) return Projection.Project(self,p,altitude) end
    return v
end

local function pointAt(v, fraction, depth)
    local distance=Config.camera.viewHeight*(Config.camera.anchorY-Config.camera.horizonY)/Config.camera.depthCompression
    local q=distance/(distance+depth)
    return {x=v.camera.x+(fraction-Config.camera.anchorX)*v.viewportWidth/(v.viewportHeight/Config.camera.viewHeight*q),
        y=v.camera.y+depth}
end

local function near(a,b,tolerance)
    assert(math.abs(a-b)<(tolerance or 1e-6),tostring(a).." ~= "..tostring(b))
end

function Tests.Run(recorder)
    local results={}
    local function check(name,fn)
        local ok,err=pcall(fn)
        results[#results+1]={name=name,passed=ok,error=not ok and tostring(err) or nil}
    end

    check("the lowest raised vertices disappear before the top as the surface recedes",function()
        local v=view()
        for _,fraction in ipairs({.05,.5,.95}) do
            local previous=-1
            for _,depth in ipairs({110,111,115,125,140,170,220,300}) do
                local p=pointAt(v,fraction,depth)
                local hidden=Projection.OccludedAltitude(v,p)
                assert(hidden>=previous,"height occlusion must increase with distance")
                previous=hidden
            end
            local p=pointAt(v,fraction,125)
            assert(Projection.Visibility(v,p,.15)<0 and Projection.Visibility(v,p,4.4)>0,
                "low hill edges must be hidden while its fixed-height top remains visible")
            local triangle={{x=p.x-2,y=p.y,altitude=.15},{x=p.x+2,y=p.y,altitude=.15},
                {x=p.x,y=p.y,altitude=4.4}}
            local projected=Geometry.ProjectPolygon(v,triangle)
            assert(#projected>=3)
            local touchesHorizon=false
            for _,vertex in ipairs(projected) do
                local gap=vertex.y-Projection.Horizon(v,vertex.x)
                assert(gap<=1e-7,"hidden raised geometry leaked below the sea boundary")
                touchesHorizon=touchesHorizon or math.abs(gap)<1e-7
            end
            assert(touchesHorizon,"partial occlusion must cut the geometry at the horizon")
        end
    end)

    check("large footprints survive center crossings including lateral screen edges",function()
        for _,size in ipairs({{1920,1080},{600,900},{800,800}}) do
            local v=view(size[1],size[2])
            for _,fraction in ipairs({0,.08,.5,.92,1}) do
                for _,depth in ipairs({110-1e-5,110,110+1e-5,111,111.9}) do
                    local p=pointAt(v,fraction,depth)
                    -- Hold the world X at the edge of the tangent frustum so
                    -- the near cap really intersects the viewport. A center
                    -- projected onto x=0 at 111.9m can have its entire near cap
                    -- outside the narrowing lateral frustum.
                    if fraction==0 or fraction==1 then p.x=pointAt(v,fraction,110).x end
                    assert(Presentation.State(v,p,2,0),"center cutoff removed a visible footprint")
                    local polygon=Geometry.ProjectPolygon(v,Geometry.SampleCircle(p,2))
                    assert(#polygon>=3,"visible footprint disappeared across the horizon")
                    for _,vertex in ipairs(polygon) do
                        assert(vertex.y>=Projection.Horizon(v,vertex.x)-1e-7)
                    end
                end
                local p=pointAt(v,fraction,112.01)
                assert(#Geometry.ProjectPolygon(v,Geometry.SampleCircle(p,2))==0)
            end
        end
    end)

    check("raised directional vectors use the same altitude as finite difference samples",function()
        local v=view()
        local step=.0001
        for _,depth in ipairs({85,109.99,110,110.01,111,125}) do
            for _,fraction in ipairs({.08,.5,.92}) do
                for _,altitude in ipairs({0,1.2,5.4}) do
                    local p=pointAt(v,fraction,depth)
                    for _,direction in ipairs({{1,0},{0,-1},{.7,.3}}) do
                        local dx,dy=direction[1],direction[2]
                        local ax,ay=Projection.Vector(v,p,dx,dy,altitude)
                        local bx,by=Projection.Project(v,{x=p.x-dx*step,y=p.y-dy*step},altitude)
                        local cx,cy=Projection.Project(v,{x=p.x+dx*step,y=p.y+dy*step},altitude)
                        near(ax,(cx-bx)/(2*step),.001)
                        near(ay,(cy-by)/(2*step),.001)
                    end
                end
            end
        end
        local _,birdY=Projection.Vector(v,pointAt(v,.5,110),0,-1,1.2)
        assert(math.abs(birdY)>.01,"bird wings used the zero ground derivative at the tangent")
    end)

    check("raised geometry at the tangent retains its real height",function()
        local v=view()
        local p=pointAt(v,.5,110)
        local vertices={{x=p.x-1,y=p.y,altitude=.1},{x=p.x+1,y=p.y,altitude=.1},
            {x=p.x,y=p.y,altitude=5.4}}
        local polygon=Geometry.ProjectPolygon(v,vertices)
        local top=math.huge
        for _,vertex in ipairs(polygon) do top=math.min(top,vertex.y) end
        assert(#polygon>=3 and top<Projection.Horizon(v,v.viewportWidth*.5)-10,
            "the ground-cap boundary must not flatten a vertical tree at the tangent")
    end)

    check("ground inverse remains unique at every lateral horizon and DPR scale",function()
        for _,size in ipairs({{1920,1080},{960,540},{390,844},{1200,1150}}) do
            local v=view(size[1],size[2])
            for _,fraction in ipairs({0,.01,.5,.99,1}) do
                local x=v.viewportWidth*fraction
                local horizon=Projection.Horizon(v,x)
                assert(Projection.Unproject(v,x,horizon)==nil)
                assert(Projection.Unproject(v,x,horizon-.00001)==nil)
                for _,offset in ipairs({.00001,.01,1,30}) do
                    local p=assert(Projection.Unproject(v,x,horizon+offset))
                    assert(p.y<v.camera.y+Config.camera.farDepth)
                    local px,py=Projection.Project(v,p)
                    near(px,x,1e-5);near(py,horizon+offset,1e-5)
                end
            end
        end
    end)

    check("actual scene renders a new float with its center beyond the tangent",function()
        local runtime=Runtime.New({initializeRegions=false,departure={x=0,y=0}})
        runtime.movement:SetViewport(1280,720)
        local p={x=runtime.movement.camera.x,y=runtime.movement.camera.y+111}
        runtime.world.entities[#runtime.world.entities+1]={id="round2-new-float",entityType="float",
            layer="surface",position=p,radius=2}
        local count,time= #runtime.world.entities,runtime.time
        recorder.reset()
        SeaDraw.Scene({},1280,720,runtime)
        assert(recorder.countFillColor(table.unpack(Config.visual.float))>0,
            "actual scene query excluded the new partially visible float")
        assert(#runtime.world.entities==count and runtime.time==time and p.y==111+runtime.movement.camera.y,
            "rendering changed authoritative world state")
    end)

    check("height broad phase is conservative and responds to configuration changes",function()
        local v=view()
        for _,height in ipairs({.15,1.2,4.4,5.4,15}) do
            local bound=Projection.VisibleDepth(v,height)
            for _,fraction in ipairs({0,.5,1}) do
                assert(Projection.Visibility(v,pointAt(v,fraction,bound+.001),height)<0)
            end
        end
        local old=Config.camera.farDepth
        local initial=Projection.VisibleDepth(v,1.2)
        Config.camera.farDepth=old+10
        local ok,err=pcall(function() assert(Projection.VisibleDepth(v,1.2)>initial) end)
        Config.camera.farDepth=old
        assert(ok,tostring(err))
        near(Projection.VisibleDepth(v,1.2),initial)
    end)
    return {results=results}
end

return Tests
