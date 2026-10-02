package io.hron;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.lang.reflect.Constructor;
import java.lang.reflect.RecordComponent;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import org.junit.jupiter.api.Test;

/** spec/README.md, "Schedules built in code": a schedule cannot change after it is built. */
class ImmutabilityTest {
  static final Set<String> LIST_COMPONENTS =
      Set.of(
          "DayFilter.days",
          "DayRepeat.times",
          "MonthRepeat.times",
          "MonthTarget.specs",
          "ScheduleData.except",
          "ScheduleData.during",
          "SingleDate.times",
          "WeekRepeat.weekDays",
          "WeekRepeat.times",
          "YearRepeat.times");

  static List<Class<?>> partTypes() throws Exception {
    return PublicSurfaceTest.exportedTypes().stream()
        .filter(t -> t.getPackageName().equals("io.hron.ast"))
        .toList();
  }

  @Test
  void everyPartHoldsOnlyUnchangeableValues() throws Exception {
    for (Class<?> type : partTypes()) {
      if (type.isEnum()) {
        continue;
      }
      if (type.isInterface()) {
        assertTrue(type.isSealed(), type.getName());
        continue;
      }
      assertTrue(type.isRecord(), type.getName());
      for (RecordComponent component : type.getRecordComponents()) {
        Class<?> value = component.getType();
        boolean unchangeable =
            value.isPrimitive()
                || value == String.class
                || value == List.class
                || value.isEnum()
                || value.getPackageName().equals("io.hron.ast");
        assertTrue(unchangeable, type.getSimpleName() + "." + component.getName());
      }
    }
  }

  @Test
  void everyListPartIsACopyThatCannotChange() throws Exception {
    Set<String> seen = new TreeSet<>();
    for (Class<?> type : partTypes()) {
      if (!type.isRecord()) {
        continue;
      }
      RecordComponent[] components = type.getRecordComponents();
      List<List<Object>> given = new ArrayList<>();
      Object[] args = new Object[components.length];
      for (int i = 0; i < components.length; i++) {
        Class<?> value = components[i].getType();
        if (value == List.class) {
          List<Object> list = new ArrayList<>();
          given.add(list);
          args[i] = list;
        } else if (value == int.class) {
          args[i] = 0;
        }
      }
      if (given.isEmpty()) {
        continue;
      }
      Constructor<?> constructor =
          type.getDeclaredConstructor(
              Arrays.stream(components).map(RecordComponent::getType).toArray(Class<?>[]::new));
      Object part = constructor.newInstance(args);
      given.forEach(list -> list.add(null));
      for (RecordComponent component : components) {
        if (component.getType() != List.class) {
          continue;
        }
        String name = type.getSimpleName() + "." + component.getName();
        seen.add(name);
        List<?> held = (List<?>) component.getAccessor().invoke(part);
        assertEquals(List.of(), held, name + " changed with the list it was given");
        assertThrows(UnsupportedOperationException.class, () -> held.add(null), name);
      }
    }
    assertEquals(new TreeSet<>(LIST_COMPONENTS), seen);
  }

  @Test
  void theListsOfAParsedScheduleCannotChange() throws Exception {
    List<String> inputs =
        List.of(
            "every monday, friday at 09:00 except dec 25, 2026-07-04 until 2027-01-01"
                + " during jan, jul in America/New_York",
            "every 2 weeks on monday, wednesday at 09:00, 17:00",
            "every month on the 1st, 10th to 15th at 09:00",
            "on 2026-03-15 at 14:30",
            "every year on dec 25 at 00:00",
            "every 30 min from 09:00 to 17:00 on weekday");
    Set<String> seen = new TreeSet<>();
    for (String input : inputs) {
      Schedule schedule = Schedule.parse(input);
      String before = schedule.toString();
      checkLists(schedule.data(), seen);
      assertEquals(before, schedule.toString());
    }
    assertEquals(new TreeSet<>(LIST_COMPONENTS), seen);
  }

  private static void checkLists(Object part, Set<String> seen) throws Exception {
    if (part == null || !part.getClass().isRecord()) {
      return;
    }
    for (RecordComponent component : part.getClass().getRecordComponents()) {
      Object value = component.getAccessor().invoke(part);
      if (value instanceof List<?> list) {
        String name = part.getClass().getSimpleName() + "." + component.getName();
        seen.add(name);
        assertThrows(UnsupportedOperationException.class, () -> list.add(null), name);
        assertThrows(UnsupportedOperationException.class, list::clear, name);
        for (Object item : list) {
          checkLists(item, seen);
        }
      } else {
        checkLists(value, seen);
      }
    }
  }
}
