from datetime import datetime, timedelta, timezone

import pytest

from home_geofence.geo import GeofenceTracker, Sample, Transition, Zone, haversine_m

HOME = (-33.4489, -70.6693)  # Plaza de Armas, Santiago
NOW = datetime(2026, 9, 17, 12, 0, tzinfo=timezone.utc)


def sample(dist_m: float, accuracy: float = 20.0, age_s: float = 0.0) -> Sample:
    """Muestra a `dist_m` metros al norte de casa (1° lat ≈ 111.32 km)."""
    lat = HOME[0] + dist_m / 111_320.0
    return Sample(latitude=lat, longitude=HOME[1], timestamp=NOW - timedelta(seconds=age_s), accuracy_m=accuracy)


def tracker(**kw) -> GeofenceTracker:
    defaults = dict(home_lat=HOME[0], home_lon=HOME[1], radius_m=100, hysteresis_m=50, confirm_samples=2)
    defaults.update(kw)
    return GeofenceTracker(**defaults)


def test_haversine_known_distance():
    # Santiago → Valparaíso ≈ 100-110 km en línea recta
    d = haversine_m(-33.4489, -70.6693, -33.0472, -71.6127)
    assert 95_000 < d < 115_000
    assert haversine_m(0, 0, 0, 0) == 0


def test_northward_helper_is_accurate():
    t = tracker()
    assert abs(t.distance_to_home(sample(500)) - 500) < 2


def test_first_fix_sets_state_without_transition():
    t = tracker(confirm_samples=1)
    ev = t.process(sample(10), NOW)
    assert ev.transition is None
    assert t.zone == Zone.INSIDE
    assert ev.reason == "estado inicial"


def test_enter_requires_confirmation_samples():
    t = tracker(confirm_samples=2)
    t.process(sample(2000), NOW)  # fija OUTSIDE
    assert t.zone == Zone.OUTSIDE
    ev1 = t.process(sample(10), NOW)
    assert ev1.transition is None and t.zone == Zone.OUTSIDE
    ev2 = t.process(sample(10), NOW)
    assert ev2.transition == Transition.ENTERED and t.zone == Zone.INSIDE


def test_single_spurious_sample_does_not_flip_state():
    t = tracker(confirm_samples=2)
    t.process(sample(2000), NOW)
    t.process(sample(10), NOW)     # 1/2 pendiente
    t.process(sample(2000), NOW)   # vuelve a fuera → se cancela lo pendiente
    ev = t.process(sample(10), NOW)
    assert ev.transition is None and t.zone == Zone.OUTSIDE


def test_hysteresis_prevents_flapping_at_the_edge():
    t = tracker(radius_m=100, hysteresis_m=50, confirm_samples=1)
    t.process(sample(10), NOW)
    assert t.zone == Zone.INSIDE
    # 120 m: fuera del radio de entrada pero dentro del de salida → sigue en casa
    ev = t.process(sample(120), NOW)
    assert ev.transition is None and t.zone == Zone.INSIDE
    # 160 m: supera radius + hysteresis → sale
    ev = t.process(sample(160), NOW)
    assert ev.transition == Transition.LEFT and t.zone == Zone.OUTSIDE
    # 120 m otra vez: no basta para volver a entrar (necesita ≤ 100)
    ev = t.process(sample(120), NOW)
    assert ev.transition is None and t.zone == Zone.OUTSIDE


def test_inaccurate_sample_is_ignored():
    t = tracker(confirm_samples=1, max_accuracy_m=250)
    t.process(sample(2000), NOW)
    ev = t.process(sample(10, accuracy=800), NOW)
    assert ev.transition is None and t.zone == Zone.OUTSIDE
    assert "precisión" in ev.reason


def test_stale_sample_is_ignored():
    t = tracker(confirm_samples=1, max_age_s=900)
    t.process(sample(2000), NOW)
    ev = t.process(sample(10, age_s=3600), NOW)
    assert ev.transition is None and t.zone == Zone.OUTSIDE
    assert "antigua" in ev.reason


def test_filters_can_be_disabled():
    t = tracker(confirm_samples=1, max_accuracy_m=None, max_age_s=None)
    t.process(sample(2000), NOW)
    ev = t.process(sample(10, accuracy=5000, age_s=99999), NOW)
    assert ev.transition == Transition.ENTERED


def test_leave_transition():
    t = tracker(confirm_samples=1)
    t.process(sample(10), NOW)
    ev = t.process(sample(1000), NOW)
    assert ev.transition == Transition.LEFT


@pytest.mark.parametrize("kw", [dict(radius_m=0), dict(hysteresis_m=-1), dict(confirm_samples=0)])
def test_invalid_parameters(kw):
    with pytest.raises(ValueError):
        tracker(**kw)
