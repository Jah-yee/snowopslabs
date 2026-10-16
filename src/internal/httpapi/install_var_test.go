// SPDX-License-Identifier: Apache-2.0

package httpapi

import (
	"strings"
	"testing"
)

// The Implementation tab explains each variable an install script reads, so
// a learner knows which ones the lab sets and which ones they must export.
func TestDescribeInstallVar(t *testing.T) {
	tests := []struct {
		name      string
		value     string
		wantValue string
		wantDesc  string
	}{
		{name: "NAMESPACE", value: "kafka", wantValue: "kafka", wantDesc: "Kubernetes namespace"},
		{name: "PROFILE", wantDesc: "(k3d | kind | incluster)"},
		{name: "GRAFANA_ADMIN_PASSWORD", wantDesc: "Secret - export this environment variable before installing"},
		{name: "VAULT_TOKEN", wantDesc: "Secret - export"},
		{name: "API_KEY", wantDesc: "Secret - export"},
		{name: "REPLICAS", wantDesc: "Environment variable read by the install script"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := describeInstallVar(tt.name, map[string]string{tt.name: tt.value})
			if got.Value != tt.wantValue {
				t.Errorf("value = %q, want %q", got.Value, tt.wantValue)
			}
			if !strings.Contains(got.Description, tt.wantDesc) {
				t.Errorf("description = %q, want it to contain %q", got.Description, tt.wantDesc)
			}
		})
	}
}
