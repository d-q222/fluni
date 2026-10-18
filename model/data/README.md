# model/data

`stanford_weather_hourly.csv`: hourly outdoor relative humidity and temperature at Stanford
(37.4275, -122.1697), Dec 2025 to Feb 2026. Columns: `t_local` (America/Los_Angeles naive local time),
`outdoor_rh_pct`, `outdoor_temp_c`. Used by `model/smf_inputs.mjs` for the humidity-dependent virus decay.
Source: Open-Meteo ERA5 archive,
https://archive-api.open-meteo.com/v1/archive?latitude=37.4275&longitude=-122.1697&start_date=2025-12-01&end_date=2026-02-28&hourly=relative_humidity_2m,temperature_2m&timezone=GMT
Fetched 2026-10-18, converted UTC to Pacific local time. Licence: CC BY 4.0 (Open-Meteo, https://open-meteo.com).
