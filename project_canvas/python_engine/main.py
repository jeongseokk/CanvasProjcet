import tempfile
from typing import List

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

try:
    from OCC.Core.BRep import BRep_Tool
    from OCC.Core.BRepAdaptor import BRepAdaptor_Curve
    from OCC.Core.BRepGProp import brepgprop_LinearProperties
    from OCC.Core.GCPnts import GCPnts_UniformAbscissa
    from OCC.Core.GProp import GProp_GProps
    from OCC.Core.STEPControl import STEPControl_Reader
    from OCC.Core.TopAbs import TopAbs_EDGE
    from OCC.Core.TopExp import TopExp_Explorer
except Exception as exc:  # pragma: no cover - optional dependency
    BRep_Tool = None
    BRepAdaptor_Curve = None
    GCPnts_UniformAbscissa = None
    STEPControl_Reader = None
    TopAbs_EDGE = None
    TopExp_Explorer = None
    brepgprop_LinearProperties = None
    GProp_GProps = None
    _IMPORT_ERROR = exc
else:
    _IMPORT_ERROR = None


app = FastAPI(title="STEP Sampling Engine")


def _require_occ() -> None:
    if _IMPORT_ERROR is not None:
        raise HTTPException(
            status_code=501,
            detail=f"pythonocc-core not available: {_IMPORT_ERROR}",
        )


def _load_step_shape(path: str):
    reader = STEPControl_Reader()
    status = reader.ReadFile(path)
    if status != 1:  # IFSelect_RetDone
        raise HTTPException(status_code=400, detail="Failed to read STEP file.")
    reader.TransferRoots()
    shape = reader.OneShape()
    return shape


def _iter_edges(shape):
    explorer = TopExp_Explorer(shape, TopAbs_EDGE)
    while explorer.More():
        yield explorer.Current()
        explorer.Next()


def _edge_length(edge) -> float:
    props = GProp_GProps()
    brepgprop_LinearProperties(edge, props)
    return props.Mass()


@app.post("/edges")
async def list_edges(file: UploadFile = File(...)):
    _require_occ()
    suffix = ".step"
    if file.filename and file.filename.lower().endswith(".stp"):
        suffix = ".stp"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    shape = _load_step_shape(tmp_path)
    edges = []
    for idx, edge in enumerate(_iter_edges(shape)):
        try:
            length = _edge_length(edge)
            name = f"Edge {idx} (len={length:.3f})"
        except Exception:
            name = f"Edge {idx}"
        edges.append({"id": str(idx), "name": name})

    return JSONResponse({"edges": edges})


@app.post("/sample")
async def sample_edge(
    file: UploadFile = File(...),
    edge_id: str = Form(...),
    step_mm: float = Form(...),
):
    _require_occ()
    if step_mm <= 0:
        raise HTTPException(status_code=400, detail="step_mm must be > 0")

    suffix = ".step"
    if file.filename and file.filename.lower().endswith(".stp"):
        suffix = ".stp"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    shape = _load_step_shape(tmp_path)
    target_index = int(edge_id)
    edge = None
    for idx, current in enumerate(_iter_edges(shape)):
        if idx == target_index:
            edge = current
            break
    if edge is None:
        raise HTTPException(status_code=404, detail="Edge not found")

    adaptor = BRepAdaptor_Curve(edge)
    # Use uniform abscissa sampling in model units (mm assumed).
    sampler = GCPnts_UniformAbscissa(adaptor, step_mm)
    points: List[dict] = []
    if sampler.IsDone() and sampler.NbPoints() > 0:
        for i in range(1, sampler.NbPoints() + 1):
            param = sampler.Parameter(i)
            pnt = adaptor.Value(param)
            points.append({"x": pnt.X(), "y": pnt.Y(), "z": pnt.Z()})
    else:
        # Fallback: sample endpoints.
        first = adaptor.FirstParameter()
        last = adaptor.LastParameter()
        p0 = adaptor.Value(first)
        p1 = adaptor.Value(last)
        points.append({"x": p0.X(), "y": p0.Y(), "z": p0.Z()})
        if first != last:
            points.append({"x": p1.X(), "y": p1.Y(), "z": p1.Z()})

    return JSONResponse({"points": points})


@app.get("/health")
def health():
    return {"ok": True}

