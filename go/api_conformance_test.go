package hron

import (
	"encoding/json"
	"fmt"
	"go/ast"
	goparser "go/parser"
	gotoken "go/token"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

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
	Name   string     `json:"name"`
	Params []struct{} `json:"params"`
	Throws bool       `json:"throws,omitempty"`
}

type GetterSpec struct {
	Name string `json:"name"`
}

type ErrorAPI struct {
	Kinds        []string     `json:"kinds"`
	Properties   []GetterSpec `json:"properties"`
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

func TestStaticMethods(t *testing.T) {
	t.Run("parse", func(t *testing.T) {
		s, err := ParseSchedule("every day at 09:00")
		if err != nil {
			t.Fatalf("Parse() failed: %v", err)
		}
		if s == nil {
			t.Error("Parse() returned nil")
		}
	})

	t.Run("fromCron", func(t *testing.T) {
		s, err := FromCronExpr("0 9 * * *")
		if err != nil {
			t.Fatalf("FromCron() failed: %v", err)
		}
		if s == nil {
			t.Error("FromCron() returned nil")
		}
	})

	t.Run("validate", func(t *testing.T) {
		if !Validate("every day at 09:00") {
			t.Error("Validate() returned false for valid expression")
		}
		if Validate("not a schedule") {
			t.Error("Validate() returned true for invalid expression")
		}
	})
}

func TestInstanceMethods(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00")
	if err != nil {
		t.Fatalf("failed to parse: %v", err)
	}

	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)

	t.Run("nextFrom", func(t *testing.T) {
		result := s.NextFrom(now)
		if result == nil {
			t.Error("NextFrom() returned nil")
		}
	})

	t.Run("nextNFrom", func(t *testing.T) {
		results := s.NextNFrom(now, 3)
		if len(results) != 3 {
			t.Errorf("NextNFrom() returned %d results, want 3", len(results))
		}
	})

	t.Run("previousFrom", func(t *testing.T) {
		result := s.PreviousFrom(now)
		if result == nil {
			t.Error("PreviousFrom() returned nil")
		}
	})

	t.Run("matches", func(t *testing.T) {
		_ = s.Matches(now)
	})

	t.Run("toCron", func(t *testing.T) {
		cron, err := s.ToCron()
		if err != nil {
			t.Fatalf("ToCron() failed: %v", err)
		}
		if cron == "" {
			t.Error("ToCron() returned empty string")
		}
	})

	t.Run("toString", func(t *testing.T) {
		str := s.String()
		if str != "every day at 09:00" {
			t.Errorf("String() = %q, want %q", str, "every day at 09:00")
		}
	})
}

func TestGetters(t *testing.T) {
	t.Run("timezone_none", func(t *testing.T) {
		s, err := ParseSchedule("every day at 09:00")
		if err != nil {
			t.Fatal(err)
		}
		if s.Timezone() != "" {
			t.Errorf("Timezone() = %q, want empty", s.Timezone())
		}
	})

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

func TestGettersReturnEachPart(t *testing.T) {
	s := MustParse("every monday, friday at 09:00, 17:00 except dec 25, 2026-12-31 until 2027-06-30 starting 2026-01-05 during jan, mar in america/new_york")
	until := NewISOUntil("2027-06-30")
	got := []any{s.Expression(), s.Except(), s.Until(), s.Starting(), s.During(), s.Timezone()}
	want := []any{
		NewDayRepeat(1, NewDayFilterDays([]Weekday{Monday, Friday}), []TimeOfDay{{9, 0}, {17, 0}}),
		[]ExceptionSpec{NewNamedException(Dec, 25), NewISOException("2026-12-31")},
		&until,
		"2026-01-05",
		[]MonthName{Jan, Mar},
		"America/New_York",
	}
	for i := range want {
		if !reflect.DeepEqual(got[i], want[i]) {
			t.Errorf("getter %d = %#v, want %#v", i, got[i], want[i])
		}
	}
}

func TestGettersOfAbsentClausesAreZero(t *testing.T) {
	s := MustParse("every day at 09:00")
	if s.Except() != nil || s.Until() != nil || s.Starting() != "" || s.During() != nil || s.Timezone() != "" {
		t.Errorf("Except() = %v, Until() = %v, Starting() = %q, During() = %v, Timezone() = %q", s.Except(), s.Until(), s.Starting(), s.During(), s.Timezone())
	}
}

func TestGettersReturnCopiesThatCannotChangeTheSchedule(t *testing.T) {
	cases := []struct {
		input  string
		mutate func(*ScheduleData)
	}{
		{"every 30 min from 09:00 to 17:00 on monday except 2026-12-25 until 2027-01-01 during jan", mutateEveryList},
		{"every monday at 09:00", mutateEveryDayList},
		{"every week on monday at 09:00", func(d *ScheduleData) { d.Expression.WeekDays[0], d.Expression.Times[0] = Friday, TimeOfDay{10, 0} }},
		{"every month on the 1st at 09:00", mutateEveryTargetList},
	}
	for _, c := range cases {
		s := MustParse(c.input)
		c.mutate(&ScheduleData{Expression: s.Expression(), Except: s.Except(), Until: s.Until(), During: s.During()})
		if s.String() != c.input || !s.Equal(MustParse(c.input)) {
			t.Errorf("a change to what the getters returned changed %q to %q", c.input, s)
		}
	}
}

func TestEqualComparesParts(t *testing.T) {
	built, err := NewSchedule(&ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), Except: []ExceptionSpec{}, During: []MonthName{}})
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		a, b  *Schedule
		equal bool
	}{
		{MustParse("every day at 9:00"), MustParse("every day at 09:00"), true},
		{MustParse("every day at 09:00"), built, true},
		{MustParse("every day at 09:00 in america/new_york"), MustParse("every day at 09:00 in America/New_York"), true},
		{MustParse("every day at 09:00"), MustParse("every day at 10:00"), false},
		{MustParse("every day at 09:00"), MustParse("every day at 09:00 in UTC"), false},
		{MustParse("every day at 09:00"), MustParse("every day at 09:00 except jan 1"), false},
		{MustParse("every day at 09:00"), MustParse("every day at 09:00 until 2026-12-31"), false},
		{MustParse("every day at 09:00"), MustParse("every day at 09:00 starting 2026-01-01"), false},
		{MustParse("every day at 09:00"), MustParse("every day at 09:00 during jan"), false},
		{MustParse("every day at 09:00 except jan 1, jan 2"), MustParse("every day at 09:00 except jan 2, jan 1"), false},
		{MustParse("every day at 09:00 during jan, jan"), MustParse("every day at 09:00 during jan"), false},
		{MustParse("every day at 09:00"), nil, false},
	}
	for _, c := range cases {
		if got := c.a.Equal(c.b); got != c.equal {
			t.Errorf("%v.Equal(%v) = %t, want %t", c.a, c.b, got, c.equal)
		}
	}
}

func TestDoubleEqualsComparesIdentity(t *testing.T) {
	a, b := MustParse("every day at 09:00"), MustParse("every day at 09:00")
	if a == b || !a.Equal(b) {
		t.Errorf("a == b is %t, a.Equal(b) is %t, want false and true", a == b, a.Equal(b))
	}
}

// spec/README.md, "Timestamps and counts": in Go a nil *Schedule or *ScheduleData panics.
func TestNilPointersPanic(t *testing.T) {
	var none *Schedule
	calls := map[string]func(){
		"NewSchedule(nil)":        func() { _, _ = NewSchedule(nil) },
		"(*Schedule)(nil).Equal":  func() { none.Equal(MustParse("every day at 09:00")) },
		"(*Schedule)(nil).String": func() { _ = none.String() },
	}
	for name, call := range calls {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("%s did not panic", name)
				}
			}()
			call()
		}()
	}
}

func TestErrorTypes(t *testing.T) {
	t.Run("error_kinds", func(t *testing.T) {
		kinds := []ErrorKind{ErrorKindLex, ErrorKindParse, ErrorKindEval, ErrorKindCron}
		expected := []string{"lex", "parse", "eval", "cron"}
		for i, k := range kinds {
			if string(k) != expected[i] {
				t.Errorf("ErrorKind %d = %q, want %q", i, string(k), expected[i])
			}
		}
	})

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

	t.Run("display_rich", func(t *testing.T) {
		err := ParseError("test error", Span{0, 4}, "test input", "")
		rich := err.DisplayRich()
		if rich == "" {
			t.Error("DisplayRich() returned empty string")
		}
	})
}

// Package functions cannot be found by reflection, so these are compile-time
// references, keyed by their api.json names.
var (
	staticMethods = map[string]any{
		"parse":    ParseSchedule,
		"fromCron": FromCronExpr,
		"validate": Validate,
	}
	errorConstructors = map[string]any{
		"lex":   LexError,
		"parse": ParseError,
		"eval":  EvalError,
		"cron":  CronError,
	}
	errorKinds = map[string]ErrorKind{
		"lex":   ErrorKindLex,
		"parse": ErrorKindParse,
		"eval":  ErrorKindEval,
		"cron":  ErrorKindCron,
	}
)

// The api.json names the Go note gives other than the camelCase name in PascalCase.
var goNames = map[string]string{"toString": "String", "equals": "Equal"}

func goName(name string) string {
	if renamed, ok := goNames[name]; ok {
		return renamed
	}
	return strings.ToUpper(name[:1]) + name[1:]
}

var errorType = reflect.TypeFor[error]()

func checkFunc(where string, fn reflect.Type, params int, throws bool) []string {
	var problems []string
	if fn.NumIn() != params {
		problems = append(problems, fmt.Sprintf("%s: takes %d arguments, api.json has %d", where, fn.NumIn(), params))
	}
	returnsError := fn.NumOut() > 0 && fn.Out(fn.NumOut()-1) == errorType
	if returnsError != throws {
		problems = append(problems, fmt.Sprintf("%s: returns an error is %t, api.json throws is %t", where, returnsError, throws))
	}
	return problems
}

func checkAPI(spec *APISpec) []string {
	var problems []string
	schedule := reflect.TypeFor[*Schedule]()
	hronError := reflect.TypeFor[HronError]()

	for _, method := range spec.Schedule.StaticMethods {
		fn, ok := staticMethods[method.Name]
		if !ok {
			problems = append(problems, "static method "+method.Name+" has no Go function")
			continue
		}
		problems = append(problems, checkFunc("static method "+method.Name, reflect.TypeOf(fn), len(method.Params), method.Throws)...)
		if out := reflect.TypeOf(fn).Out(0); method.Name != "validate" && out != schedule {
			problems = append(problems, "static method "+method.Name+" returns "+out.String())
		}
	}
	for _, method := range spec.Schedule.InstanceMethods {
		m, ok := schedule.MethodByName(goName(method.Name))
		if !ok {
			problems = append(problems, "instance method "+method.Name+" has no method "+goName(method.Name))
			continue
		}
		// The receiver is the first argument of a method expression.
		problems = append(problems, checkFunc("instance method "+method.Name, m.Type, len(method.Params)+1, method.Throws)...)
	}
	for _, getter := range spec.Schedule.Getters {
		m, ok := schedule.MethodByName(goName(getter.Name))
		if !ok || m.Type.NumIn() != 1 || m.Type.NumOut() != 1 {
			problems = append(problems, "getter "+getter.Name+" has no method "+goName(getter.Name)+"() with one result")
		}
	}

	for _, kind := range spec.Error.Kinds {
		if got, ok := errorKinds[kind]; !ok || string(got) != kind {
			problems = append(problems, "error kind "+kind+" has no ErrorKind constant")
		}
	}
	for _, property := range spec.Error.Properties {
		if _, ok := hronError.FieldByName(goName(property.Name)); !ok {
			problems = append(problems, "error property "+property.Name+" has no field "+goName(property.Name))
		}
	}
	for _, method := range spec.Error.Methods {
		m, ok := reflect.PointerTo(hronError).MethodByName(goName(method.Name))
		if !ok {
			problems = append(problems, "error method "+method.Name+" has no method "+goName(method.Name))
			continue
		}
		problems = append(problems, checkFunc("error method "+method.Name, m.Type, len(method.Params)+1, method.Throws)...)
	}
	for _, kind := range spec.Error.Constructors {
		fn, ok := errorConstructors[kind]
		if !ok {
			problems = append(problems, "error constructor "+kind+" has no Go function")
			continue
		}
		f := reflect.ValueOf(fn)
		args := make([]reflect.Value, f.Type().NumIn())
		for i := range args {
			args[i] = reflect.Zero(f.Type().In(i))
		}
		built, ok := f.Call(args)[0].Interface().(*HronError)
		if !ok || string(built.Kind) != kind {
			problems = append(problems, "error constructor "+kind+" does not build a *HronError of kind "+kind)
		}
	}
	return problems
}

func TestAPIMatchesSpec(t *testing.T) {
	for _, problem := range checkAPI(loadAPISpec(t)) {
		t.Error(problem)
	}
}

func TestAPICheckReportsNamesGoLacks(t *testing.T) {
	spec := loadAPISpec(t)
	spec.Schedule.StaticMethods = append(spec.Schedule.StaticMethods, MethodSpec{Name: "fakeStatic"})
	spec.Schedule.InstanceMethods = append(spec.Schedule.InstanceMethods, MethodSpec{Name: "fakeMethod"})
	spec.Schedule.Getters = append(spec.Schedule.Getters, GetterSpec{Name: "fakeGetter"})
	spec.Error.Kinds = append(spec.Error.Kinds, "fakeKind")
	spec.Error.Properties = append(spec.Error.Properties, GetterSpec{Name: "fakeProperty"})
	spec.Error.Methods = append(spec.Error.Methods, MethodSpec{Name: "fakeErrorMethod"})
	spec.Error.Constructors = append(spec.Error.Constructors, "fakeConstructor")
	spec.Schedule.InstanceMethods = append(spec.Schedule.InstanceMethods, MethodSpec{Name: "matches", Params: make([]struct{}, 1), Throws: true})
	spec.Schedule.StaticMethods = append(spec.Schedule.StaticMethods, MethodSpec{Name: "parse", Params: make([]struct{}, 2), Throws: true})

	problems := checkAPI(spec)
	for _, fake := range []string{"fakeStatic", "fakeMethod", "fakeGetter", "fakeKind", "fakeProperty", "fakeErrorMethod", "fakeConstructor", "instance method matches", "static method parse"} {
		if !slices.ContainsFunc(problems, func(p string) bool { return strings.Contains(p, fake) }) {
			t.Errorf("checkAPI did not report %s; it reported %q", fake, problems)
		}
	}
	if len(problems) != 9 {
		t.Errorf("checkAPI reported %d problems, want 9: %q", len(problems), problems)
	}
}

func exportedIdentifiers(t *testing.T) []string {
	paths, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, path := range paths {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		file, err := goparser.ParseFile(gotoken.NewFileSet(), path, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range file.Decls {
			switch decl := decl.(type) {
			case *ast.FuncDecl:
				names = append(names, funcName(decl))
			case *ast.GenDecl:
				for _, spec := range decl.Specs {
					switch spec := spec.(type) {
					case *ast.TypeSpec:
						names = append(names, spec.Name.Name)
						if fields, ok := spec.Type.(*ast.StructType); ok {
							for _, field := range fields.Fields.List {
								for _, name := range field.Names {
									names = append(names, spec.Name.Name+"."+name.Name)
								}
							}
						}
					case *ast.ValueSpec:
						for _, name := range spec.Names {
							names = append(names, name.Name)
						}
					}
				}
			}
		}
	}
	// A method or field is public only when its type is too.
	names = slices.DeleteFunc(names, func(name string) bool {
		return slices.ContainsFunc(strings.Split(name, "."), func(part string) bool { return !ast.IsExported(part) })
	})
	return names
}

func funcName(decl *ast.FuncDecl) string {
	if decl.Recv == nil {
		return decl.Name.Name
	}
	receiver := decl.Recv.List[0].Type
	if star, ok := receiver.(*ast.StarExpr); ok {
		receiver = star.X
	}
	return receiver.(*ast.Ident).Name + "." + decl.Name.Name
}

func TestExportedIdentifiersMatchAllowlist(t *testing.T) {
	allowed := []string{
		"Apr", "Aug", "CronError", "DateSpec", "DateSpec.Date", "DateSpec.Day", "DateSpec.Kind", "DateSpec.Month",
		"DateSpecKind", "DateSpecKindISO", "DateSpecKindNamed", "DayFilter", "DayFilter.Days", "DayFilter.Kind",
		"DayFilterKind", "DayFilterKindDays", "DayFilterKindEvery", "DayFilterKindWeekday", "DayFilterKindWeekend",
		"DayOfMonthSpec", "DayOfMonthSpec.Day", "DayOfMonthSpec.End", "DayOfMonthSpec.Expand", "DayOfMonthSpec.Kind",
		"DayOfMonthSpec.Start", "DayOfMonthSpecKind", "DayOfMonthSpecKindRange", "DayOfMonthSpecKindSingle", "Dec",
		"ErrorKind", "ErrorKindCron", "ErrorKindEval", "ErrorKindLex", "ErrorKindParse", "EvalError",
		"ExceptionSpec", "ExceptionSpec.Date", "ExceptionSpec.Day", "ExceptionSpec.Kind", "ExceptionSpec.Month",
		"ExceptionSpecKind", "ExceptionSpecKindISO", "ExceptionSpecKindNamed", "Feb", "Fifth", "First", "Fourth",
		"Friday", "FromCronExpr", "HronError", "HronError.DisplayRich", "HronError.Error", "HronError.Input",
		"HronError.Kind", "HronError.Message", "HronError.Span", "HronError.Suggestion", "IntervalHours",
		"IntervalMin", "IntervalUnit", "IntervalUnit.String", "Jan", "Jul", "Jun", "Last", "LexError", "Mar", "May",
		"Monday", "MonthName", "MonthName.Number", "MonthName.String", "MonthTarget", "MonthTarget.Day",
		"MonthTarget.Direction", "MonthTarget.ExpandDays", "MonthTarget.Kind", "MonthTarget.Ordinal",
		"MonthTarget.Specs", "MonthTarget.Weekday", "MonthTargetKind", "MonthTargetKindDays",
		"MonthTargetKindLastDay", "MonthTargetKindLastWeekday", "MonthTargetKindNearestWeekday",
		"MonthTargetKindOrdinalWeekday", "MustParse", "NearestDirection", "NearestNext", "NearestNone",
		"NearestPrevious", "NewDayFilterDays", "NewDayFilterEvery", "NewDayFilterWeekday", "NewDayFilterWeekend",
		"NewDayRange", "NewDayRepeat", "NewDaysTarget", "NewISODate", "NewISOException", "NewISOUntil",
		"NewIntervalRepeat", "NewLastDayTarget", "NewLastWeekdayTarget", "NewMonthRepeat", "NewNamedDate",
		"NewNamedException", "NewNamedUntil", "NewNearestWeekdayTarget", "NewOrdinalWeekdayTarget", "NewSchedule",
		"NewScheduleData", "NewSingleDateExpr", "NewSingleDay", "NewWeekRepeat", "NewYearDateTarget",
		"NewYearDayOfMonthTarget", "NewYearLastWeekdayTarget", "NewYearOrdinalWeekdayTarget", "NewYearRepeat", "Nov",
		"Oct", "OrdinalPosition", "OrdinalPosition.String", "OrdinalPosition.ToN", "ParseError", "ParseMonthName",
		"ParseOrdinalPosition", "ParseSchedule", "ParseWeekday", "Saturday", "Schedule", "Schedule.Between",
		"Schedule.Data", "Schedule.During", "Schedule.Equal", "Schedule.Except", "Schedule.Expression",
		"Schedule.Matches", "Schedule.NextFrom", "Schedule.NextNFrom", "Schedule.Occurrences",
		"Schedule.PreviousFrom", "Schedule.Starting", "Schedule.String", "Schedule.Timezone", "Schedule.ToCron",
		"Schedule.Until", "ScheduleData", "ScheduleData.During", "ScheduleData.Except", "ScheduleData.Expression",
		"ScheduleData.Starting", "ScheduleData.Timezone", "ScheduleData.Until", "ScheduleExpr",
		"ScheduleExpr.DateSpec", "ScheduleExpr.DayFilter", "ScheduleExpr.Days", "ScheduleExpr.FromTime",
		"ScheduleExpr.Interval", "ScheduleExpr.Kind", "ScheduleExpr.MonthTarget", "ScheduleExpr.Times",
		"ScheduleExpr.ToTime", "ScheduleExpr.Unit", "ScheduleExpr.WeekDays", "ScheduleExpr.YearTarget",
		"ScheduleExprKind", "ScheduleExprKindDay", "ScheduleExprKindInterval", "ScheduleExprKindMonth",
		"ScheduleExprKindSingleDate", "ScheduleExprKindWeek", "ScheduleExprKindYear", "Second", "Sep", "Span",
		"Span.End", "Span.Start", "Sunday", "Third", "Thursday", "TimeOfDay", "TimeOfDay.Hour", "TimeOfDay.Minute",
		"TimeOfDay.String", "TimeOfDay.TotalMinutes", "Tuesday", "UntilSpec", "UntilSpec.Date", "UntilSpec.Day",
		"UntilSpec.Kind", "UntilSpec.Month", "UntilSpecKind", "UntilSpecKindISO", "UntilSpecKindNamed", "Validate",
		"Version", "Wednesday", "Weekday", "Weekday.CronDOW", "Weekday.Number", "Weekday.String",
		"WeekdayFromNumber", "YearTarget", "YearTarget.Day", "YearTarget.Kind", "YearTarget.Month",
		"YearTarget.Ordinal", "YearTarget.Weekday", "YearTargetKind", "YearTargetKindDate",
		"YearTargetKindDayOfMonth", "YearTargetKindLastWeekday", "YearTargetKindOrdinalWeekday",
	}
	exported := exportedIdentifiers(t)
	for _, name := range exported {
		if !slices.Contains(allowed, name) {
			t.Errorf("%s is exported but not in the allowlist", name)
		}
	}
	for _, name := range allowed {
		if !slices.Contains(exported, name) {
			t.Errorf("%s is in the allowlist but not exported", name)
		}
	}
}
