package main

import (
	"math"
	"strings"
)

// minorUnitExponent is the ISO 4217 exponent: most currencies have 2 decimals,
// zero-decimal currencies (JPY, KRW) have none.
var minorUnitExponent = map[string]int{"JPY": 0, "KRW": 0}

// toMinorUnits converts a major-unit amount to minor units for PSP v2:
// 12.50 USD -> 1250, 1500 JPY -> 1500.
func toMinorUnits(amount float64, currency string) int64 {
	exp, ok := minorUnitExponent[strings.ToUpper(currency)]
	if !ok {
		exp = 2
	}
	return int64(math.Round(amount * math.Pow10(exp)))
}
