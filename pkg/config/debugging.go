package config

import (
	"fmt"
	"strings"
)

// Use the upper-case version of the word to match the kubebuilder
// default.
const defaultLogLevel = "Normal"

type Debugging struct {
	// Valid values are: "Normal", "Debug", "Trace", "TraceAll".
	// Defaults to "Normal".
	// +kubebuilder:default="Normal"
	LogLevel string `json:"logLevel"`
}

var logLevelNames = map[string]int{
	"normal":   2,
	"debug":    4,
	"trace":    6,
	"traceall": 10,
}

// computeLoggingSetting validates the logging setting and saves a
// warning if there is an issue.
func (c *Config) computeLoggingSetting() {
	_, ok := logLevelNames[strings.ToLower(c.Debugging.LogLevel)]
	if !ok {
		if c.Debugging.LogLevel != "" {
			c.AddWarning(fmt.Sprintf("Unrecognized log level %q, defaulting to %q",
				c.Debugging.LogLevel, defaultLogLevel))
		}
		// Reset the value so that `show-config` reports the value
		// being used instead of the value in the config file.
		c.Debugging.LogLevel = defaultLogLevel
	}
}

// GetVerbosity returns the numerical value for LogLevel which is an
// enum.
func (c *Config) GetVerbosity() int {
	verbosity, ok := logLevelNames[strings.ToLower(c.Debugging.LogLevel)]
	if !ok {
		verbosity = 2
	}
	return verbosity
}
