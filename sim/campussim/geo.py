"""Campus-local equirectangular projection (meters). Matches the d2 mock run (sim/runs/mock_boring10):
origin = SW corner of the OSM bbox, x east, y north."""
import math

import numpy as np

LAT0 = 37.418
LON0 = -122.182
KX = 111320 * math.cos(math.radians(LAT0))  # meters per degree lon
KY = 110540                                   # meters per degree lat


def to_xy(lon, lat):
    """lon/lat (scalars or arrays) -> campus-local x (east), y (north) in meters."""
    return (np.asarray(lon) - LON0) * KX, (np.asarray(lat) - LAT0) * KY


def to_ll(x, y):
    """campus-local meters -> (lon, lat)."""
    return np.asarray(x) / KX + LON0, np.asarray(y) / KY + LAT0
