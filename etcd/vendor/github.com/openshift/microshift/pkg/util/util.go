package util

import (
	"errors"
	"fmt"
	"os"
)

func Must(err error) {
	if err != nil {
		panic(fmt.Errorf("internal error: %v", err))
	}
}

func Default(s string, defaultS string) string {
	if s == "" {
		return defaultS
	}
	return s
}

func CheckIfFileExists(path string) (bool, error) {
	if _, err := os.Stat(path); err == nil {
		return true, nil
	} else if errors.Is(err, os.ErrNotExist) {
		return false, nil
	} else {
		return false, err
	}
}
