// Builds and meshes a box against an occt-build install prefix, and checks
// that an OCCT exception arrives as a std::exception (OCCT 8).

#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Version.hxx>
#include <Standard_VersionInfo.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <gp_Dir.hxx>

#include <cstdio>
#include <cstring>
#include <exception>

static int fail(const char* what)
{
  std::fprintf(stderr, "smoke: %s\n", what);
  return 1;
}

int main()
{
  if (std::strcmp(OCC_VERSION_COMPLETE, OCCT_Version_String_Complete()) != 0)
    return fail("the headers and the libraries report different versions");
  std::printf("OCCT %s\n", OCCT_Version_String_Complete());

  TopoDS_Shape box = BRepPrimAPI_MakeBox(10.0, 20.0, 30.0).Shape();
  BRepMesh_IncrementalMesh mesh(box, 0.1, false, 0.5, false);
  if (!mesh.IsDone())
    return fail("meshing failed");

  int faces = 0, triangles = 0;
  for (TopExp_Explorer it(box, TopAbs_FACE); it.More(); it.Next())
  {
    TopLoc_Location location;
    const occ::handle<Poly_Triangulation>& triangulation =
      BRep_Tool::Triangulation(TopoDS::Face(it.Current()), location);
    if (triangulation.IsNull())
      return fail("a face has no triangulation");
    ++faces;
    triangles += triangulation->NbTriangles();
  }
  std::printf("box: %d faces, %d triangles\n", faces, triangles);
  if (faces != 6 || triangles < 12)
    return fail("unexpected box mesh");

  try
  {
    gp_Dir zero(0.0, 0.0, 0.0);
    (void)zero;
    return fail("a zero-length gp_Dir did not throw");
  }
  catch (const std::exception& e)
  {
    std::printf("caught: %s\n", e.what());
  }
  return 0;
}
