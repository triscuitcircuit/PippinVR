#include "NewtXRApp.h"
#include "InteractionGeometry.h"
#include "HandOcclusion.h"
#include "FractalDecoration.h"
void NewtXR::CreateRenderAssets() {
    const std::vector<Vec3> cube = MakeCube();
    mCubeBuffer = mCore->CreateBuffer(cube.size() * sizeof(Vec3), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mCubeBuffer, cube.data(), cube.size() * sizeof(Vec3));
    mCubeCount = static_cast<uint32_t>(cube.size());
    const Vec3 corners[8] = {{-.5f,-.5f,-.5f}, {.5f,-.5f,-.5f}, {.5f,.5f,-.5f}, {-.5f,.5f,-.5f},
                             {-.5f,-.5f,.5f}, {.5f,-.5f,.5f}, {.5f,.5f,.5f}, {-.5f,.5f,.5f}};
    const int edges[12][2] = {{0,1},{1,2},{2,3},{3,0},{4,5},{5,6},{6,7},{7,4},{0,4},{1,5},{2,6},{3,7}};
    std::vector<Vec3> cubeEdges;
    for (const auto& edge : edges) { cubeEdges.push_back(corners[edge[0]]); cubeEdges.push_back(corners[edge[1]]); }
    mCubeEdges = mCore->CreateBuffer(cubeEdges.size() * sizeof(Vec3), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mCubeEdges, cubeEdges.data(), cubeEdges.size() * sizeof(Vec3));
    const auto cut = customui::MakeSponge(1), fractal = customui::MakeSponge(2);
    auto uploadDecoration = [&](const std::vector<Vec3>& points, Buffer& buffer, uint32_t& count) {
        buffer = mCore->CreateBuffer(points.size() * sizeof(Vec3), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        mCore->UploadBuffer(buffer, points.data(), points.size() * sizeof(Vec3));
        count = static_cast<uint32_t>(points.size());
    };
    uploadDecoration(cut.triangles, mCutCube, mCutCubeCount);
    uploadDecoration(cut.edges, mCutCubeEdges, mCutCubeEdgeCount);
    uploadDecoration(fractal.triangles, mFractalCube, mFractalCubeCount);
    uploadDecoration(fractal.edges, mFractalCubeEdges, mFractalCubeEdgeCount);

    const std::vector<Vec3> grid = MakeGrid();
    mGridBuffer = mCore->CreateBuffer(grid.size() * sizeof(Vec3), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mGridBuffer, grid.data(), grid.size() * sizeof(Vec3));
    mGridCount = static_cast<uint32_t>(grid.size());

    const Vec3 rayVerts[] = { { 0.0f, 0.0f, 0.0f }, { 0.0f, 0.0f, -1.0f } };
    mRayBuffer = mCore->CreateBuffer(sizeof(rayVerts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mRayBuffer, rayVerts, sizeof(rayVerts));

    const auto tube = MakeHandTube(), ball = MakeHandBall();
    mHandTube = mCore->CreateBuffer(tube.size() * sizeof(VertexPC), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mHandTube, tube.data(), tube.size() * sizeof(VertexPC));
    mHandTubeCount = static_cast<uint32_t>(tube.size());
    mHandBall = mCore->CreateBuffer(ball.size() * sizeof(VertexPC), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mHandBall, ball.data(), ball.size() * sizeof(VertexPC));
    mHandBallCount = static_cast<uint32_t>(ball.size());

    const auto dock = MakeDock();
    mDockBuffer = mCore->CreateBuffer(dock.size()*sizeof(VertexPC), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mDockBuffer, dock.data(), dock.size()*sizeof(VertexPC));
    for(int button=0;button<9;++button) for(int selected=0;selected<2;++selected) {
        auto mesh=MakeDockButton(button,selected!=0);int index=button*2+selected;
        mButtonFaces[index]=mCore->CreateBuffer(mesh.face.size()*sizeof(VertexPC),VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        mCore->UploadBuffer(mButtonFaces[index],mesh.face.data(),mesh.face.size()*sizeof(VertexPC));
        mButtonBodies[index]=mCore->CreateBuffer(mesh.body.size()*sizeof(Vec3),VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        mCore->UploadBuffer(mButtonBodies[index],mesh.body.data(),mesh.body.size()*sizeof(Vec3));
    }
    mCore->CreateTexture(mLogoTexture, 256, 256); mCore->UpdateTexture(mLogoTexture, RenderLogo());
    mCore->CreateTexture(mBarTexture, 1024, 64); mCore->UpdateTexture(mBarTexture, RenderPanelBar());
    for(int i=0;i<9;++i) { mCore->CreateTexture(mButtonTextures[i],88,82); mCore->UpdateTexture(mButtonTextures[i],RenderDockButton(i,i==mSelected)); }
    mCore->CreateTexture(mModelPopupTexture, 1024, 256);
    mCore->UpdateTexture(mModelPopupTexture, RenderModelPopup(-1, 1.0f, true));
    mCore->CreateTexture(mWristClockTexture, 512, 192);
    mCore->UpdateTexture(mWristClockTexture, RenderWristClock(WristClockText(mClockSettings), mClockSettings));
    mCore->CreateTexture(mMetricsTexture, 1024, 512);
    mCore->UpdateTexture(mMetricsTexture, RenderMetricsGraph(MetricsSnapshot{}));
    mCore->CreateTexture(mMenuTexture, 1024, 160);
    mCore->CreateTexture(mContentTexture);
    mCore->UpdateTexture(mMenuTexture, RenderMenu(mSelected, mNotice.c_str(), false));
    mCore->UpdateTexture(mContentTexture, RenderContent(mPage,mGridColor,mMediaVolume,mApps,mClockSettings,mSettingsTab,mPassthrough,mAudio.mode));
    mRenderedMenuSelected = mSelected;
    mRenderedPage = mPage;
    mContentDirty = false;
}
