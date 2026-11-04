// Package pspsandbox simulates an EXTERNAL payment service provider (PSP).
//
// It stands in for a third-party API we do not own, so treat it as a vendor
// dependency: its contract and limits are fixed. Do not modify this package to
// make a failing charge pass — fix the caller.
package pspsandbox

import (
	"context"
	"fmt"
	"math"
	"math/rand/v2"
	"strings"
	"time"
)

// exponent is the ISO 4217 minor-unit exponent: USD has cents (2), JPY has none (0).
var exponent = map[string]int{"USD": 2, "EUR": 2, "GBP": 2, "SGD": 2, "JPY": 0, "KRW": 0}

// perTxnLimitMinor is the risk limit per transaction, in minor units.
var perTxnLimitMinor = map[string]int64{
	"USD": 1_000_000, // $10,000.00
	"EUR": 1_000_000, // €10,000.00
	"GBP": 1_000_000,
	"SGD": 1_000_000,
	"JPY": 50_000, // ¥50,000
	"KRW": 5_000_000,
}

// Charge is a successful authorization.
type Charge struct {
	ID          string `json:"id"`
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
}

// Error is a PSP rejection.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return fmt.Sprintf("psp %s: %s", e.Code, e.Message) }

func latency(ctx context.Context) error {
	select {
	case <-time.After(time.Duration(8+rand.IntN(20)) * time.Millisecond):
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// ChargeV1 is the legacy API: amount in major units (e.g. 12.50 USD, 1500 JPY).
// The PSP converts to minor units itself, so callers never think about exponents.
func ChargeV1(ctx context.Context, amount float64, currency string) (*Charge, error) {
	exp, ok := exponent[strings.ToUpper(currency)]
	if !ok {
		return nil, &Error{"unsupported_currency", currency}
	}
	return ChargeV2(ctx, int64(math.Round(amount*math.Pow10(exp))), currency)
}

// ChargeV2 is the new API: amount in minor units. The caller owns the conversion.
func ChargeV2(ctx context.Context, amountMinor int64, currency string) (*Charge, error) {
	if err := latency(ctx); err != nil {
		return nil, err
	}
	currency = strings.ToUpper(currency)
	limit, ok := perTxnLimitMinor[currency]
	if !ok {
		return nil, &Error{"unsupported_currency", currency}
	}
	if amountMinor <= 0 {
		return nil, &Error{"invalid_amount", fmt.Sprintf("amount_minor=%d must be positive", amountMinor)}
	}
	if amountMinor > limit {
		return nil, &Error{"limit_exceeded", fmt.Sprintf("amount_minor=%d exceeds per-transaction limit %d for %s", amountMinor, limit, currency)}
	}
	return &Charge{ID: fmt.Sprintf("ch_%x", rand.Int64()), AmountMinor: amountMinor, Currency: currency}, nil
}
