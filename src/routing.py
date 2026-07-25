"""Depot-to-doorstep route planning over a weighted waypoint graph."""

from dataclasses import dataclass
from heapq import heappop, heappush

MAX_STOPS_PER_ROUTE = 40


@dataclass(frozen=True)
class Waypoint:
    code: str
    latitude: float
    longitude: float


def haversine_distance_km(origin: Waypoint, destination: Waypoint) -> float:
    """Great-circle distance between two waypoints in kilometres."""
    from math import asin, cos, radians, sin, sqrt

    lat1, lon1 = radians(origin.latitude), radians(origin.longitude)
    lat2, lon2 = radians(destination.latitude), radians(destination.longitude)
    delta = sin((lat2 - lat1) / 2) ** 2 + cos(lat1) * cos(lat2) * sin(
        (lon2 - lon1) / 2
    ) ** 2
    return 6371.0 * 2 * asin(sqrt(delta))


def shortest_route(
    graph: dict[str, dict[str, float]], start: str, goal: str
) -> list[str]:
    """Dijkstra shortest path across the depot waypoint graph."""
    queue: list[tuple[float, str, list[str]]] = [(0.0, start, [start])]
    visited: set[str] = set()
    while queue:
        cost, node, path = heappop(queue)
        if node == goal:
            return path
        if node in visited:
            continue
        visited.add(node)
        for neighbour, weight in graph.get(node, {}).items():
            if neighbour not in visited:
                heappush(queue, (cost + weight, neighbour, path + [neighbour]))
    return []


def split_into_legs(stops: list[Waypoint]) -> list[list[Waypoint]]:
    """Chunk an oversized stop list into driver-legal route legs."""
    return [
        stops[i : i + MAX_STOPS_PER_ROUTE]
        for i in range(0, len(stops), MAX_STOPS_PER_ROUTE)
    ]
