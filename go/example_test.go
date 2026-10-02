package hron_test

import (
	"fmt"

	"github.com/simpllyf/hron/go/v2"
)

func ExampleNewSchedule() {
	schedule, err := hron.NewSchedule(&hron.ScheduleData{
		Expr:     hron.NewDayRepeat(1, hron.NewDayFilterWeekday(), []hron.TimeOfDay{{Hour: 9, Minute: 0}}),
		Timezone: "america/new_york",
		Anchor:   "2026-01-05",
	})
	if err != nil {
		panic(err)
	}
	fmt.Println(schedule)

	data := schedule.Data()
	data.Expr.Interval = 2
	_, err = hron.NewSchedule(data)
	fmt.Println(err.(*hron.HronError).DisplayRich())
	// Output:
	// every weekday at 09:00 starting 2026-01-05 in America/New_York
	// error: days must be every day when the interval is above 1
}
