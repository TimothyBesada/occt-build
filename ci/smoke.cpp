// Builds and meshes a box against an occt-build install prefix, writes it as
// STEP AP203, AP214 and AP242 and reads each back, and checks that an OCCT
// exception arrives as a std::exception (OCCT 8).

#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRep_Tool.hxx>
#include <Interface_Static.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <Standard_Version.hxx>
#include <Standard_VersionInfo.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <gp_Dir.hxx>

#include <cstdio>
#include <cstring>
#include <exception>
#include <sstream>
#include <string>

static int fail(const char* what)
{
  std::fprintf(stderr, "smoke: %s\n", what);
  return 1;
}

static int count(const TopoDS_Shape& shape, TopAbs_ShapeEnum type)
{
  int n = 0;
  for (TopExp_Explorer it(shape, type); it.More(); it.Next())
    ++n;
  return n;
}

// Writes the shape as STEP in the given schema, checks the file's schema
// name, reads it back, and checks the result is one solid with six faces.
static int roundTripStep(const TopoDS_Shape& shape, const char* schema, const char* fileSchema)
{
  STEPControl_Writer writer;
  if (!Interface_Static::SetCVal("write.step.schema", schema))
    return fail("cannot set write.step.schema");
  if (writer.Transfer(shape, STEPControl_AsIs) != IFSelect_RetDone)
    return fail("STEP transfer failed");
  std::ostringstream out;
  if (writer.WriteStream(out) != IFSelect_RetDone)
    return fail("STEP write failed");
  const std::string text = out.str();
  if (text.find(fileSchema) == std::string::npos)
    return fail("the STEP file does not name the expected schema");

  STEPControl_Reader reader;
  std::istringstream in(text);
  if (reader.ReadStream("box.step", in) != IFSelect_RetDone)
    return fail("STEP read failed");
  if (reader.TransferRoots() < 1)
    return fail("STEP read transferred no roots");
  const TopoDS_Shape read = reader.OneShape();
  const int solids = count(read, TopAbs_SOLID), faces = count(read, TopAbs_FACE);
  std::printf("STEP %s: %zu bytes, read back %d solid(s), %d faces\n",
              schema, text.size(), solids, faces);
  if (solids != 1 || faces != 6)
    return fail("unexpected shape read back from STEP");
  return 0;
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

  if (roundTripStep(box, "AP203", "CONFIG_CONTROL_DESIGN") != 0
      || roundTripStep(box, "AP214IS", "AUTOMOTIVE_DESIGN") != 0
      || roundTripStep(box, "AP242DIS", "AP242_MANAGED_MODEL_BASED_3D_ENGINEERING") != 0)
    return 1;

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
