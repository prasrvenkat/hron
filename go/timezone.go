package hron

import (
	"archive/zip"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// resolveTimezone returns the location and canonical name for tzName, and UTC
// for an empty name so results never depend on the host zone.
func resolveTimezone(tzName string) (*time.Location, string, error) {
	if tzName == "" {
		return time.UTC, "", nil
	}
	canonical, ok := canonicalTimezone(tzName)
	if !ok {
		return nil, "", &HronError{Kind: ErrorKindParse, Message: unknownTimezoneMessage(tzName)}
	}
	loc, err := time.LoadLocation(canonical)
	if err != nil {
		return nil, "", &HronError{Kind: ErrorKindParse, Message: unknownTimezoneMessage(tzName)}
	}
	return loc, canonical, nil
}

func unknownTimezoneMessage(name string) string {
	return fmt.Sprintf("unknown timezone %q: use UTC or an IANA Area/Location name such as America/New_York", name)
}

// canonicalTimezone returns the IANA spelling of name, which matches in any
// case: "UTC", or an Area/Location zone or link name. Abbreviations, offsets,
// non-ASCII and unknown names, and the SystemV, posix and right trees that some
// systems ship are rejected (spec/README.md, "Parse-time validation").
func canonicalTimezone(name string) (string, bool) {
	if strings.EqualFold(name, "UTC") {
		return "UTC", true
	}
	area, _, found := strings.Cut(name, "/")
	if !found || !isASCII(name) {
		return "", false
	}
	switch strings.ToLower(area) {
	case "systemv", "posix", "right":
		return "", false
	}
	// The index decides when it can be built: on a case-insensitive file system
	// LoadLocation accepts any case and would keep the caller's spelling.
	index := zoneNameIndex()
	if len(index) == 0 {
		_, err := time.LoadLocation(name)
		return name, err == nil
	}
	canonical, ok := index[strings.ToLower(name)]
	if !ok {
		return "", false
	}
	_, err := time.LoadLocation(canonical)
	return canonical, err == nil
}

// zoneNameIndex maps lowercased zone names to their IANA spelling, from every
// zone database Go's time package can read and this package can list. Go has
// no API that lists zones, and the embedded time/tzdata cannot be listed.
var zoneNameIndex = sync.OnceValue(func() map[string]string {
	index := map[string]string{}
	add := func(name string) {
		if _, seen := index[strings.ToLower(name)]; !seen {
			index[strings.ToLower(name)] = name
		}
	}
	sources := []string{os.Getenv("ZONEINFO"), "/usr/share/zoneinfo", "/usr/share/lib/zoneinfo", "/usr/lib/locale/TZ", "/etc/zoneinfo"}
	if goroot := runtime.GOROOT(); goroot != "" {
		sources = append(sources, filepath.Join(goroot, "lib", "time", "zoneinfo.zip"))
	}
	for _, source := range sources {
		if source != "" {
			addZoneNames(source, add)
		}
	}
	return index
})

// addZoneNames lists the zone names in a zoneinfo directory or zip file. The
// source is resolved first because WalkDir does not follow a symlinked root,
// as /usr/share/zoneinfo is on macOS and NixOS.
func addZoneNames(source string, add func(string)) {
	source, err := filepath.EvalSymlinks(source)
	if err != nil {
		return
	}
	info, err := os.Stat(source)
	if err != nil {
		return
	}
	if !info.IsDir() {
		if archive, err := zip.OpenReader(source); err == nil {
			for _, file := range archive.File {
				add(file.Name)
			}
			_ = archive.Close()
		}
		return
	}
	_ = filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(source, path)
		if rel != "." && (entry.Type().IsRegular() || entry.Type()&fs.ModeSymlink != 0) {
			add(filepath.ToSlash(rel))
		}
		return nil
	})
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}
