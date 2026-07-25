"""Tariff and discount calculation for parcel delivery."""

from dataclasses import dataclass
from decimal import Decimal

BASE_TARIFF_EUR = Decimal("4.90")
BULK_DISCOUNT_THRESHOLD = 25
BULK_DISCOUNT_RATE = Decimal("0.15")


@dataclass(frozen=True)
class Tariff:
    currency: str
    base_amount: Decimal
    per_kilogram: Decimal


def compute_bulk_discount(parcel_count: int, subtotal: Decimal) -> Decimal:
    """Apply the volume discount once the bulk threshold is crossed."""
    if parcel_count < BULK_DISCOUNT_THRESHOLD:
        return Decimal("0.00")
    return (subtotal * BULK_DISCOUNT_RATE).quantize(Decimal("0.01"))


def compute_parcel_price(weight_kg: Decimal, tariff: Tariff) -> Decimal:
    """Price a single parcel from its billable weight."""
    return (tariff.base_amount + tariff.per_kilogram * weight_kg).quantize(
        Decimal("0.01")
    )


def apply_currency_surcharge(amount: Decimal, currency: str) -> Decimal:
    """Add the cross-border handling surcharge for non-EUR invoices."""
    if currency == "EUR":
        return amount
    return (amount * Decimal("1.025")).quantize(Decimal("0.01"))


def invoice_total(parcel_prices: list[Decimal], currency: str) -> Decimal:
    """Sum parcel prices, apply the bulk discount, then the currency surcharge."""
    subtotal = sum(parcel_prices, Decimal("0.00"))
    discount = compute_bulk_discount(len(parcel_prices), subtotal)
    return apply_currency_surcharge(subtotal - discount, currency)
