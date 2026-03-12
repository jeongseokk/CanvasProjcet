# STEP Sampling Engine

Minimal Python server that loads STEP files and samples edges.

## Setup

```powershell
cd project_canvas/python_engine
python -m venv .venv
.venv\\Scripts\\activate
pip install -r requirements.txt
```

## Run

```powershell
uvicorn main:app --host 0.0.0.0 --port 8000
```

## API

- `POST /edges` (multipart: file)
  - Response:
    ```json
    { "edges": [ { "id": "0", "name": "Edge 0 (len=12.345)" } ] }
    ```

- `POST /sample` (multipart: file, edge_id, step_mm)
  - Response:
    ```json
    { "points": [ { "x": 0, "y": 1, "z": 2 } ] }
    ```

## Notes

- Requires `pythonocc-core`.
- Units are assumed to be the native STEP units (typically mm).
