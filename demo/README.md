# demo/: the pitch demo

One page for presenting FlUni: the problem, what's wrong with existing apps, the live bird's-eye
simulation next to one agent's phone, the two-phone proximity flow, the maths, and app-vs-no-app
simulation results. Owner: @aidenyj (see WORKSTREAMS.md). Reads other workstreams' output, never edits it.

## Run it

Serve the **repo root** (the live section embeds `heatmap/` and reads `sim/runs/`):

```bash
python3 heatmap/tools/serve.py    # then open http://localhost:8000/demo/
```

## Layout

- `index.html`: the shell, sticky nav, and one `<section class="slide">` per part.
- `style.css`: shared look (the heat map's campfire palette); sections reuse its classes
  (`.card`, `.grid`, `.pill`, `button.btn`, `.muted`, `.math`).
- `sections/<id>.js`: one ES module per section, `export function mount(el)`, which fills its
  `<section id="<id>">`. Section-only CSS is injected by the module, scoped under `#<id>`.
  Ids: `problem`, `live`, `phones`, `math`, `results`.
- `data/compare.json`: app vs no-app runs, from `tools/compare.py` (see its docstring).
