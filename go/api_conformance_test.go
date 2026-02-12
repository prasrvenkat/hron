package hron

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

// API spec structure
type APISpec struct {
	Schedule ScheduleAPI `json:"schedule"`
	Error    ErrorAPI    `json:"error"`
}

type ScheduleAPI struct {
	StaticMethods   []MethodSpec `json:"staticMethods"`
	InstanceMethods []MethodSpec `json:"instanceMethods"`
	Getters         []GetterSpec `json:"getters"`
}

type MethodSpec struct {
	Name   string `json:"name"`
	Throws bool   `json:"throws,omitempty"`
}

type GetterSpec struct {
	Name string `json:"name"`
}

type ErrorAPI struct {
	Kinds        []string     `json:"kinds"`
	Constructors []string     `json:"constructors"`
	Methods      []MethodSpec `json:"methods"`
}

func loadAPISpec(t *testing.T) *APISpec {
	data, err := os.ReadFile("../spec/api.json")
	if err != nil {
		t.Fatalf("failed to read API spec: %v", err)
	}

	var spec APISpec
	if err := json.Unmarshal(data, &spec); err != nil {
		t.Fatalf("failed to parse API spec: %v", err)
	}
	return &spec
}

// TestStaticMethods verifies that all static methods from the spec exist.
func TestStaticMethods(t *testing.T) {
	// Test Parse exists and works
	t.Run("parse", func(t *testing.T) {
		s, err := ParseSchedule("every day at 09:00")
		if err != nil {
			t.Fatalf("Parse() failed: %v", err)
		}
		if s == nil {
			t.Error("Parse() returned nil")
		}
	})

	// Test FromCron exists and works
	t.Run("fromCron", func(t *testing.T) {
		s, err := FromCronExpr("0 9 * * *")
		if err != nil {
			t.Fatalf("FromCron() failed: %v", err)
		}
		if s == nil {
			t.Error("FromCron() returned nil")
		}
	})

	// Test Validate exists and works
	t.Run("validate", func(t *testing.T) {
		if !Validate("every day at 09:00") {
			t.Error("Validate() returned false for valid expression")
		}
		if Validate("not a schedule") {
			t.Error("Validate() returned true for invalid expression")
		}
	})
}

// TestInstanceMethods verifies that all instance methods from the spec exist.
func TestInstanceMethods(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00")
	if err != nil {
		t.Fatalf("failed to parse: %v", err)
	}

	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)

	// Test NextFrom
	t.Run("nextFrom", func(t *testing.T) {
		result := s.NextFrom(now)
		if result == nil {
			t.Error("NextFrom() returned nil")
		}
	})

	// Test NextNFrom
	t.Run("nextNFrom", func(t *testing.T) {
		results := s.NextNFrom(now, 3)
		if len(results) != 3 {
			t.Errorf("NextNFrom() returned %d results, want 3", len(results))
		}
	})

	// Test Matches
	t.Run("matches", func(t *testing.T) {
		// Just verify the method exists and returns a bool
		_ = s.Matches(now)
	})

	// Test ToCron
	t.Run("toCron", func(t *testing.T) {
		cron, err := s.ToCron()
		if err != nil {
			t.Fatalf("ToCron() failed: %v", err)
		}
		if cron == "" {
			t.Error("ToCron() returned empty string")
		}
	})

	// Test String
	t.Run("toString", func(t *testing.T) {
		str := s.String()
		if str != "every day at 09:00" {
			t.Errorf("String() = %q, want %q", str, "every day at 09:00")
		}
	})
}

// TestGetters verifies that all getters from the spec exist.
func TestGetters(t *testing.T) {
	// Timezone() returns empty string when not specified
	t.Run("timezone_none", func(t *testing.T) {
		s, err := ParseSchedule("every day at 09:00")
		if err != nil {
			t.Fatal(err)
		}
		if s.Timezone() != "" {
			t.Errorf("Timezone() = %q, want empty", s.Timezone())
		}
	})

	// Timezone() returns IANA name when specified
	t.Run("timezone_present", func(t *testing.T) {
		s, err := ParseSchedule("every day at 09:00 in America/New_York")
		if err != nil {
			t.Fatal(err)
		}
		if s.Timezone() != "America/New_York" {
			t.Errorf("Timezone() = %q, want %q", s.Timezone(), "America/New_York")
		}
	})
}

// TestErrorTypes verifies that all error types and constructors exist.
func TestErrorTypes(t *testing.T) {
	// Test error kinds
	t.Run("error_kinds", func(t *testing.T) {
		kinds := []ErrorKind{ErrorKindLex, ErrorKindParse, ErrorKindEval, ErrorKindCron}
		expected := []string{"lex", "parse", "eval", "cron"}
		for i, k := range kinds {
			if string(k) != expected[i] {
				t.Errorf("ErrorKind %d = %q, want %q", i, string(k), expected[i])
			}
		}
	})

	// Test error constructors
	t.Run("lex_constructor", func(t *testing.T) {
		err := LexError("test", Span{0, 1}, "input")
		if err.Kind != ErrorKindLex {
			t.Errorf("LexError().Kind = %v, want %v", err.Kind, ErrorKindLex)
		}
	})

	t.Run("parse_constructor", func(t *testing.T) {
		err := ParseError("test", Span{0, 1}, "input", "suggestion")
		if err.Kind != ErrorKindParse {
			t.Errorf("ParseError().Kind = %v, want %v", err.Kind, ErrorKindParse)
		}
	})

	t.Run("eval_constructor", func(t *testing.T) {
		err := EvalError("test")
		if err.Kind != ErrorKindEval {
			t.Errorf("EvalError().Kind = %v, want %v", err.Kind, ErrorKindEval)
		}
	})

	t.Run("cron_constructor", func(t *testing.T) {
		err := CronError("test")
		if err.Kind != ErrorKindCron {
			t.Errorf("CronError().Kind = %v, want %v", err.Kind, ErrorKindCron)
		}
	})

	// Test DisplayRich method
	t.Run("display_rich", func(t *testing.T) {
		err := ParseError("test error", Span{0, 4}, "test input", "")
		rich := err.DisplayRich()
		if rich == "" {
			t.Error("DisplayRich() returned empty string")
		}
	})
}

// TestSpecCoverage verifies that all methods from api.json are implemented.
func TestSpecCoverage(t *testing.T) {
	spec := loadAPISpec(t)

	// Map camelCase spec names to Go equivalents
	staticMethodMap := map[string]string{
		"parse":    "ParseSchedule",
		"fromCron": "FromCronExpr",
		"validate": "Validate",
	}

	instanceMethodMap := map[string]string{
		"nextFrom":  "NextFrom",
		"nextNFrom": "NextNFrom",
		"matches":   "Matches",
		"toCron":    "ToCron",
		"toString":  "String",
	}

	getterMap := map[string]string{
		"timezone": "Timezone",
	}

	t.Run("static_methods_exist", func(t *testing.T) {
		for _, method := range spec.Schedule.StaticMethods {
			goName, ok := staticMethodMap[method.Name]
			if !ok {
				t.Errorf("unmapped spec static method: %s", method.Name)
				continue
			}
			// We verify these exist by compiling - if they don't exist, the code won't compile
			_ = goName
		}
	})

	t.Run("instance_methods_exist", func(t *testing.T) {
		for _, method := range spec.Schedule.InstanceMethods {
			goName, ok := instanceMethodMap[method.Name]
			if !ok {
				t.Errorf("unmapped spec instance method: %s", method.Name)
				continue
			}
			_ = goName
		}
	})

	t.Run("getters_exist", func(t *testing.T) {
		for _, getter := range spec.Schedule.Getters {
			goName, ok := getterMap[getter.Name]
			if !ok {
				t.Errorf("unmapped spec getter: %s", getter.Name)
				continue
			}
			_ = goName
		}
	})

	t.Run("error_kinds_match_spec", func(t *testing.T) {
		expectedKinds := map[string]bool{"lex": true, "parse": true, "eval": true, "cron": true}
		for _, kind := range spec.Error.Kinds {
			if !expectedKinds[kind] {
				t.Errorf("unexpected error kind in spec: %s", kind)
			}
		}
	})

	t.Run("error_constructors_exist", func(t *testing.T) {
		constructorMap := map[string]bool{
			"lex":   true,
			"parse": true,
			"eval":  true,
			"cron":  true,
		}
		for _, constructor := range spec.Error.Constructors {
			if !constructorMap[constructor] {
				t.Errorf("missing error constructor: %s", constructor)
			}
		}
	})

	t.Run("error_display_rich_exists", func(t *testing.T) {
		for _, method := range spec.Error.Methods {
			if method.Name == "displayRich" {
				// Verify DisplayRich exists by calling it
				err := EvalError("test message")
				_ = err.DisplayRich()
			}
		}
	})
}
