package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestGetVerbosity(t *testing.T) {
	var ttests = []struct {
		setting  string
		level    int
		warnings int
	}{
		{
			setting:  "Normal",
			level:    2,
			warnings: 0,
		},
		{
			setting:  "normal",
			level:    2,
			warnings: 0,
		},
		{
			setting:  "Debug",
			level:    4,
			warnings: 0,
		},
		{
			setting:  "debug",
			level:    4,
			warnings: 0,
		},
		{
			setting:  "Trace",
			level:    6,
			warnings: 0,
		},
		{
			setting:  "trace",
			level:    6,
			warnings: 0,
		},
		{
			setting:  "TraceAll",
			level:    10,
			warnings: 0,
		},
		{
			setting:  "traceall",
			level:    10,
			warnings: 0,
		},
		{
			setting:  "Unknown",
			level:    2,
			warnings: 1,
		},
		{
			setting:  "unknown",
			level:    2,
			warnings: 1,
		},
		{
			setting:  "",
			level:    2,
			warnings: 0,
		},
	}

	for _, tt := range ttests {
		t.Run(tt.setting, func(t *testing.T) {
			config := NewDefault()
			config.Debugging.LogLevel = tt.setting
			config.computeLoggingSetting()
			verbosity := config.GetVerbosity()
			assert.Equal(t, tt.level, verbosity)
			assert.Equal(t, tt.warnings, len(config.Warnings))
		})
	}
}
