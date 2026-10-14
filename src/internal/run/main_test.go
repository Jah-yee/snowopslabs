// SPDX-License-Identifier: Apache-2.0

package run

import (
	"testing"

	"go.uber.org/goleak"
)

// TestMain fails the package's tests if any of them leaves a goroutine
// running: a worker, stream reader or timer that outlives its run would keep
// a script's pipes and the store open in the real binary.
func TestMain(m *testing.M) {
	goleak.VerifyTestMain(m)
}
