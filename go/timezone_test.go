package hron

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestAddZoneNamesFollowsSymlinkedRoot(t *testing.T) {
	dir := t.TempDir()
	zoneinfo := filepath.Join(dir, "zoneinfo")
	if err := os.MkdirAll(filepath.Join(zoneinfo, "America"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(zoneinfo, "America", "New_York"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(zoneinfo, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	var names []string
	addZoneNames(link, func(name string) { names = append(names, name) })

	if !slices.Equal(names, []string{"America/New_York"}) {
		t.Errorf("addZoneNames(symlinked root) = %q, want [America/New_York]", names)
	}
}

func TestNewScheduleStoresCanonicalTimezone(t *testing.T) {
	data := &ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), []TimeOfDay{{Hour: 9}}), Timezone: "america/new_york"}
	s, err := NewSchedule(data)
	if err != nil {
		t.Fatal(err)
	}
	if s.Timezone() != "America/New_York" || s.String() != "every day at 09:00 in America/New_York" {
		t.Errorf("Timezone() = %q, String() = %q, want the canonical America/New_York", s.Timezone(), s.String())
	}
	if data.Timezone != "america/new_york" {
		t.Errorf("NewSchedule changed the caller's data to %q", data.Timezone)
	}
}
