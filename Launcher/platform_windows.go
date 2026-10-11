//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"unsafe"
)

func launchPowerShellManager(manager string) error {
	cmd := exec.Command(
		"powershell.exe",
		"-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
		"-STA", "-WindowStyle", "Hidden", "-File", manager,
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd.Start()
}

func showError(title, message string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	messageBox := user32.NewProc("MessageBoxW")
	text, _ := syscall.UTF16PtrFromString(message)
	caption, _ := syscall.UTF16PtrFromString(title)
	_, _, _ = messageBox.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(caption)), 0x10)
}
