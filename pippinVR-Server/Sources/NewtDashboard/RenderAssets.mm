#include "NewtXRApp.h"
#include "InteractionGeometry.h"
void NewtXR::CreateRenderAssets() {
    const std::vector<Vec3> cube = MakeCube();
    mCubeBuffer = mCore->CreateBuffer(cube.size() * sizeof(Vec3), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mCubeBuffer, cube.data(), cube.size() * sizeof(Vec3));
    mCubeCount = static_cast<uint32_t>(cube.size());

    const std::vector<Vec3> grid = MakeGrid();
    mGridBuffer = mCore->CreateBuffer(grid.size() * sizeof(Vec3), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mGridBuffer, grid.data(), grid.size() * sizeof(Vec3));
    mGridCount = static_cast<uint32_t>(grid.size());

    const Vec3 rayVerts[] = { { 0.0f, 0.0f, 0.0f }, { 0.0f, 0.0f, -1.0f } };
    mRayBuffer = mCore->CreateBuffer(sizeof(rayVerts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    mCore->UploadBuffer(mRayBuffer, rayVerts, sizeof(rayVerts));

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
    mCore->CreateTexture(mMenuTexture, 1024, 160);
    mCore->CreateTexture(mContentTexture);
    mCore->UpdateTexture(mMenuTexture, RenderMenu(mSelected, mNotice.c_str(), false));
    mCore->UpdateTexture(mContentTexture, RenderContent(mPage,mGridColor,mMediaVolume));
    mRenderedMenuSelected = mSelected;
    mRenderedPage = mPage;
    mContentDirty = false;
}
