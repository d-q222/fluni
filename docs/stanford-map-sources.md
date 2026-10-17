# Stanford map data sources

Reference for whoever needs realistic campus locations, e.g. the synthetic-data or heat map work.

## OpenStreetMap (used in the repo; ODbL, credit required)

- **Building outlines:** `heatmap/data/stanford_buildings.json`, from `heatmap/tools/fetch_buildings.py`.
- **Walkway graph:** `heatmap/data/stanford_paths.json`, from `heatmap/tools/fetch_paths.py`.

## Stanford Searchable Map (campus-map.stanford.edu)

This is Stanford's own data. Don't commit copies to this public repo. Fetch it locally if you need it.

- **Every campus building:** https://campus-map.stanford.edu/kml/Stanford_Buildings.kmz has 1,365
  building outlines, each with the official building ID (`BLDG_ID`, e.g. `10-132`) and `NAME`.
  These are the names students actually use, so they're useful for matching CSV building names.
- **Points of interest by category:** the map's script (`/js/stan_cm_js.cfm`) holds about 2,400
  markers. Useful layers for semi-realistic schedules:
  - `acad0`: 53 academic departments
  - `din0`: 46 dining spots (dining halls, cafés, Tresidder)
  - `lib0`: 17 libraries
  - `rec`: 18 recreation sites (pools, fields, gyms)
  - `hfd0`: 8 housing service centres
- Other layers include the pedestrian zone (`Pedestrian_Zone.kmz`), Wi-Fi coverage, and AEDs.
