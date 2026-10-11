//go:build !windows

package main

import (
	"errors"
	"fmt"
)

func launchPowerShellManager(manager string) error {
	return errors.New("the launcher is Windows-only")
}

func showError(title, message string) {
	fmt.Printf("%s: %s\n", title, message)
}
