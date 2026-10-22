#ifndef NEWT_INTERACTIONGEOMETRY_H
#define NEWT_INTERACTIONGEOMETRY_H
#include "Newt/MathTypes.h"
#include <algorithm>

constexpr float kDockRadius = 1.25f;
constexpr float kDockArc = 1.44f;
constexpr float kDockY = -0.75f;
constexpr float kDockHeight = 0.28125f;
constexpr int kDockSegments = 48;

inline XrPosef DockPose(float u, float radius = kDockRadius) {
    const float angle = (u - 0.5f) * kDockArc;
    XrPosef p = IdentityPose();
    p.position = {radius * std::sin(angle), kDockY, -radius * std::cos(angle)};
    p.orientation = {0, std::sin(-angle / 2), 0, std::cos(-angle / 2)};
    return p;
}
inline XrPosef ComposePose(const XrPosef& a, const XrPosef& b) {
    const Vec3 delta = Rotate(a.orientation, {b.position.x, b.position.y, b.position.z});
    return {QuaternionProduct(a.orientation, b.orientation),
        {a.position.x + delta.x, a.position.y + delta.y, a.position.z + delta.z}};
}
inline bool RayQuad(const XrPosef& ray, const XrPosef& panel, float width, float height, float& distance, float& u) {
    const auto inverse = Conjugate(panel.orientation);
    const Vec3 origin = Rotate(inverse, {ray.position.x-panel.position.x, ray.position.y-panel.position.y, ray.position.z-panel.position.z});
    const Vec3 direction = Rotate(inverse, Rotate(ray.orientation, {0, 0, -1}));
    if (std::abs(direction.z) < 1e-6f) return false;
    const float t = -origin.z / direction.z;
    if (t <= 0) return false;
    const Vec3 hit = origin + direction*t;
    if (std::abs(hit.x) > width/2 || std::abs(hit.y) > height/2) return false;
    distance = t; u = hit.x / width + 0.5f; return true;
}
inline bool RayDock(const Vec3& origin, const Vec3& direction, float& distance, float& u, float& v, float radius = kDockRadius) {
    const float a = direction.x*direction.x + direction.z*direction.z;
    const float b = 2*(origin.x*direction.x + origin.z*direction.z);
    const float c = origin.x*origin.x + origin.z*origin.z - radius*radius;
    const float disc = b*b - 4*a*c;
    if (a < 1e-8f || disc < 0) return false;
    const float roots[] = {(-b-std::sqrt(disc))/(2*a), (-b+std::sqrt(disc))/(2*a)};
    for (float t : roots) {
        if (t <= 0) continue;
        const Vec3 hit = origin + direction*t;
        const float angle = std::atan2(hit.x, -hit.z);
        if (std::abs(angle) > kDockArc/2 || std::abs(hit.y-kDockY) > kDockHeight/2) continue;
        distance = t; u = angle/kDockArc + 0.5f; v = 0.5f-(hit.y-kDockY)/kDockHeight; return true;
    }
    return false;
}
inline std::vector<VertexPC> MakeDock() {
    std::vector<VertexPC> out;
    for (int i=0; i<kDockSegments; ++i) {
        float u0=float(i)/kDockSegments, u1=float(i+1)/kDockSegments;
        const auto p0=DockPose(u0).position, p1=DockPose(u1).position;
        VertexPC a{{p0.x,kDockY-kDockHeight/2,p0.z},{u0,1}}, b{{p1.x,kDockY-kDockHeight/2,p1.z},{u1,1}},
            c{{p1.x,kDockY+kDockHeight/2,p1.z},{u1,0}}, d{{p0.x,kDockY+kDockHeight/2,p0.z},{u0,0}};
        out.insert(out.end(), {a,b,c,a,c,d});
    }
    return out;
}
inline XrPosef PanelBarPose(const XrPosef& panel, float height) {
    auto offset=IdentityPose(); offset.position={0, -(height/2 + 0.0575f), 0.015f};
    return ComposePose(panel, offset);
}
inline int PanelBarZone(float u) { return u<0.12f ? 0 : u>0.88f ? 3 : u>0.78f ? 2 : 1; }

inline Vec3 ScreenPoint(float u, float v, float arc) {
    if (arc < 0.001f) return {u-0.5f, 0.5f-v, 0};
    float a=(u-0.5f)*arc;
    return {std::sin(a)/arc, 0.5f-v, (1-std::cos(a))/arc};
}
inline std::vector<VertexPC> MakeScreen(float arc, int mode=0) {
    std::vector<VertexPC> result;
    auto vertex=[&](float u,float v) {
        const auto p=ScreenPoint(u,v,arc);
        float tu=u,tv=v;
        if(mode==1 || mode==2) tu=u*0.5f+(mode==2?0.5f:0);
        if(mode==3 || mode==4) tv=v*0.5f+(mode==4?0.5f:0);
        return VertexPC{{p.x,p.y,p.z},{tu,tv}};
    };
    for(int i=0;i<48;++i) {
        float a=float(i)/48,b=float(i+1)/48;
        result.insert(result.end(),{vertex(a,1),vertex(b,1),vertex(b,0),vertex(a,1),vertex(b,0),vertex(a,0)});
    }
    return result;
}

inline bool RayScreen(const XrPosef& ray,const XrPosef& pose,float width,float arc,float& distance,float& u,float height=-1) {
    if(height<0) height=width*0.625f;
    if(arc<0.001f) return RayQuad(ray,pose,width,height,distance,u);
    const auto q=Conjugate(pose.orientation);
    const Vec3 o=Rotate(q,{ray.position.x-pose.position.x,ray.position.y-pose.position.y,ray.position.z-pose.position.z});
    const Vec3 d=Rotate(q,Rotate(ray.orientation,{0,0,-1}));
    auto dot=[](Vec3 a,Vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;};
    auto cross=[](Vec3 a,Vec3 b){return Vec3{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};};
    bool found=false;distance=1000;
    for(int i=0;i<48;++i) {
        float u0=float(i)/48,u1=float(i+1)/48;
        Vec3 a=ScreenPoint(u0,0.5f,arc)*width,b=ScreenPoint(u1,0.5f,arc)*width;
        Vec3 edge=b-a,n=cross(edge,{0,1,0});float denominator=dot(d,n);
        if(std::abs(denominator)<1e-6f) continue;
        float t=dot(a-o,n)/denominator;
        Vec3 h=o+d*t;float f=dot(h-a,edge)/dot(edge,edge);
        if(t>0 && t<distance && f>=0 && f<=1 && std::abs(h.y)<=height/2) {
            found=true;distance=t;u=u0+(u1-u0)*f;
        }
    }
    return found;
}

inline std::vector<VertexPC> MakePanelBar(float arc) {
    auto vertices=MakeScreen(arc);
    // x/z scale with screen width, but bar height stays a fixed 75 mm
    // (drawn with Scale({width,1,width}) -- Y isn't touched at draw time,
    // so the unit mesh's own Y range has to already equal 0.075).
    for(auto& vertex:vertices) vertex.pos[1]*=0.075f;
    return vertices;
}

inline std::vector<VertexPC> MakeEnvironmentSphere(int lonSegments=48, int latSegments=24) {
    std::vector<VertexPC> out;
    auto vertex=[&](int loni,int lati) {
        const float lon=(float(loni)/lonSegments)*6.2831853f;
        const float lat=(float(lati)/latSegments)*3.14159265f;
        const float x=std::sin(lat)*std::cos(lon), y=std::cos(lat), z=std::sin(lat)*std::sin(lon);
        return VertexPC{{x,y,z},{float(loni)/lonSegments,float(lati)/latSegments}};
    };
    for(int lati=0;lati<latSegments;++lati) {
        for(int loni=0;loni<lonSegments;++loni) {
            auto a=vertex(loni,lati),b=vertex(loni+1,lati),c=vertex(loni+1,lati+1),d=vertex(loni,lati+1);
            out.insert(out.end(), {a,c,b, a,d,c});
        }
    }
    return out;
}

constexpr float kAppsRowX = 70;
constexpr float kAppsRowWidth = 840;
constexpr float kAppsRowTop = 145;
constexpr float kAppsRowStride = 92;
constexpr float kAppsRowHeight = 76;
constexpr int kAppsVisible = 4;
inline int AppsRowAt(float x, float y, int count) {
    if (x < kAppsRowX || x > kAppsRowX + kAppsRowWidth) return -1;
    const int shown = std::min(count, kAppsVisible);
    for (int i = 0; i < shown; ++i) {
        const float top = kAppsRowTop + i * kAppsRowStride;
        if (y >= top && y <= top + kAppsRowHeight) return 110 + i;
    }
    return -1;
}

constexpr int kButtonSegments=24;
constexpr int kButtonFaceCount=kButtonSegments*6;
constexpr int kButtonBodyCount=kButtonSegments*24+12;
inline float ButtonRadius(bool selected) { return kDockRadius-(selected?0.008f:0.035f)-0.016f; }
struct DockButtonMesh { std::vector<VertexPC> face; std::vector<Vec3> body; };
inline DockButtonMesh MakeDockButton(int button,bool selected) {
    DockButtonMesh mesh;
    const float u0=(148+button*95)/1024.0f,u1=(148+button*95+88)/1024.0f;
    const float radius=ButtonRadius(selected),back=radius+0.031f;
    const float top=kDockY+(0.5f-46.0f/160)*kDockHeight,bottom=kDockY+(0.5f-128.0f/160)*kDockHeight;
    auto point=[&](float u,float y,float r) { auto p=DockPose(u,r).position;return Vec3{p.x,y,p.z}; };
    auto quad=[&](Vec3 a,Vec3 b,Vec3 c,Vec3 d){mesh.body.insert(mesh.body.end(),{a,b,c,a,c,d});};
    for(int i=0;i<kButtonSegments;++i) {
        float s0=float(i)/kButtonSegments,s1=float(i+1)/kButtonSegments;
        float a=u0+(u1-u0)*s0,b=u0+(u1-u0)*s1;
        auto ab=point(a,bottom,radius),bb=point(b,bottom,radius),bt=point(b,top,radius),at=point(a,top,radius);
        VertexPC va{{ab.x,ab.y,ab.z},{s0,1}},vb{{bb.x,bb.y,bb.z},{s1,1}},vc{{bt.x,bt.y,bt.z},{s1,0}},vd{{at.x,at.y,at.z},{s0,0}};
        mesh.face.insert(mesh.face.end(),{va,vb,vc,va,vc,vd});
        auto backAB=point(a,bottom,back),backBB=point(b,bottom,back),backBT=point(b,top,back),backAT=point(a,top,back);
        quad(backBB,backAB,backAT,backBT);
        quad(at,bt,backBT,backAT);quad(bb,ab,backAB,backBB);
        quad(point(a,bottom,radius+0.001f),point(b,bottom,radius+0.001f),point(b,top,radius+0.001f),point(a,top,radius+0.001f));
    }
    quad(point(u0,bottom,back),point(u0,bottom,radius),point(u0,top,radius),point(u0,top,back));
    quad(point(u1,bottom,radius),point(u1,bottom,back),point(u1,top,back),point(u1,top,radius));
    return mesh;
}

#endif // NEWT_INTERACTIONGEOMETRY_H
