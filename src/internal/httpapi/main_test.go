// SPDX-License-Identifier: Apache-2.0

package httpapi

import (
	"testing"

	"go.uber.org/goleak"
)

// TestMain fails the package's tests if any of them leaves a goroutine
// running: a job, stream or poller that outlives its request would hold a
// script's pipes and the run store open in the real server.
func TestMain(m *testing.M) {
	goleak.VerifyTestMain(m)
}
