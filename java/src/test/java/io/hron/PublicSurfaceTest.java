package io.hron;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.hron.ast.OrdinalPosition;
import io.hron.internal.ScheduleData;
import java.io.IOException;
import java.lang.module.ModuleDescriptor;
import java.lang.reflect.Constructor;
import java.lang.reflect.Executable;
import java.lang.reflect.GenericArrayType;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.Type;
import java.lang.reflect.WildcardType;
import java.net.URISyntaxException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;

/** spec/README.md, "Schedules built in code". */
class PublicSurfaceTest {
  static final Set<String> EXPORTED = Set.of("io.hron", "io.hron.ast");

  static List<Class<?>> exportedTypes() throws IOException, URISyntaxException {
    Path classes =
        Path.of(Schedule.class.getProtectionDomain().getCodeSource().getLocation().toURI());
    List<Class<?>> types = new ArrayList<>();
    for (String pkg : EXPORTED) {
      try (Stream<Path> files = Files.list(classes.resolve(pkg.replace('.', '/')))) {
        for (Path file : files.filter(f -> f.toString().endsWith(".class")).toList()) {
          String simple = file.getFileName().toString().replace(".class", "");
          Class<?> type = load(pkg + "." + simple);
          if (isPublic(type)) {
            types.add(type);
          }
        }
      }
    }
    return types;
  }

  private static Class<?> load(String name) {
    try {
      return Class.forName(name);
    } catch (ClassNotFoundException e) {
      throw new AssertionError(e);
    }
  }

  private static boolean isPublic(Class<?> type) {
    for (Class<?> t = type; t != null; t = t.getEnclosingClass()) {
      if (!Modifier.isPublic(t.getModifiers()) || t.isAnonymousClass() || t.isSynthetic()) {
        return false;
      }
    }
    return true;
  }

  @Test
  void theModuleExportsOnlyTheApiAndTheReadOnlyParts() {
    Module module = Schedule.class.getModule();
    assertTrue(module.isNamed(), "tests must run on the module path to check its exports");
    Set<String> exports =
        module.getDescriptor().exports().stream()
            .peek(e -> assertTrue(e.targets().isEmpty(), e + " is a qualified export"))
            .map(ModuleDescriptor.Exports::source)
            .collect(Collectors.toSet());
    assertEquals(EXPORTED, exports);
    assertTrue(module.getPackages().contains("io.hron.internal.eval"));
  }

  @Test
  void theExportedPackagesHoldExactlyTheseTypes() throws Exception {
    Set<String> names = new TreeSet<>();
    for (Class<?> type : exportedTypes()) {
      names.add(type.getName().replace('$', '.'));
    }
    Set<String> ast =
        Stream.of(
                "DateSpec",
                "DateSpec.Kind",
                "DayFilter",
                "DayFilter.Kind",
                "DayOfMonthSpec",
                "DayOfMonthSpec.Kind",
                "DayRepeat",
                "ExceptionSpec",
                "ExceptionSpec.Kind",
                "IntervalRepeat",
                "IntervalUnit",
                "MonthName",
                "MonthRepeat",
                "MonthTarget",
                "MonthTarget.Kind",
                "NearestDirection",
                "OrdinalPosition",
                "ScheduleExpr",
                "SingleDate",
                "TimeOfDay",
                "UntilSpec",
                "UntilSpec.Kind",
                "WeekRepeat",
                "Weekday",
                "YearRepeat",
                "YearTarget",
                "YearTarget.Kind")
            .map(n -> "io.hron.ast." + n)
            .collect(Collectors.toSet());
    Set<String> expected = new TreeSet<>(ast);
    expected.addAll(
        Set.of("io.hron.ErrorKind", "io.hron.HronException", "io.hron.Schedule", "io.hron.Span"));
    assertEquals(expected, names);
  }

  @Test
  void scheduleDataIsNotExported() throws Exception {
    assertFalse(EXPORTED.contains(ScheduleData.class.getPackageName()));
    assertFalse(exportedTypes().contains(ScheduleData.class));
  }

  @Test
  void onlyParseAndFromCronMakeASchedule() throws Exception {
    Set<String> makers = new TreeSet<>();
    for (Class<?> type : exportedTypes()) {
      for (Method method : type.getDeclaredMethods()) {
        if (Modifier.isPublic(method.getModifiers()) && method.getReturnType() == Schedule.class) {
          makers.add(type.getSimpleName() + "." + method.getName());
        }
      }
    }
    assertEquals(Set.of("Schedule.parse", "Schedule.fromCron"), makers);
    assertEquals(0, Schedule.class.getConstructors().length);
    assertTrue(Modifier.isFinal(Schedule.class.getModifiers()));
  }

  @Test
  void noPublicFunctionOutsideThePartsTakesAPart() throws Exception {
    List<String> takers = new ArrayList<>();
    for (Class<?> type : exportedTypes()) {
      if (!type.getPackageName().equals("io.hron")) {
        continue;
      }
      List<Executable> executables = new ArrayList<>(List.of(type.getDeclaredMethods()));
      executables.addAll(List.of(type.getDeclaredConstructors()));
      for (Executable executable : executables) {
        if (!Modifier.isPublic(executable.getModifiers())) {
          continue;
        }
        for (Class<?> parameter : executable.getParameterTypes()) {
          if (parameter.getPackageName().equals("io.hron.ast") || parameter == ScheduleData.class) {
            takers.add(executable.toString());
          }
        }
      }
    }
    assertEquals(List.of(), takers);
  }

  // Without the module path, public classes of io.hron.internal are reachable, so none of them
  // may take a part that Schedule has not checked. A name is an enum, always one of its kind.
  @Test
  void noPublicFunctionOfTheInternalPackagesTakesAPartOtherThanAName() throws Exception {
    Path classes =
        Path.of(Schedule.class.getProtectionDomain().getCodeSource().getLocation().toURI());
    List<String> takers = new ArrayList<>();
    List<Path> files;
    try (Stream<Path> walk = Files.walk(classes.resolve("io/hron/internal"))) {
      files = walk.filter(f -> f.toString().endsWith(".class")).toList();
    }
    assertTrue(files.size() > 10, "found " + files);
    for (Path file : files) {
      String name = classes.relativize(file).toString().replace(".class", "").replace('/', '.');
      Class<?> type = load(name);
      if (!isPublic(type)) {
        continue;
      }
      List<Executable> executables = new ArrayList<>(List.of(type.getDeclaredMethods()));
      executables.addAll(List.of(type.getDeclaredConstructors()));
      for (Executable executable : executables) {
        // Unchecked parts in a ScheduleData are harmless while nothing public takes one.
        boolean exempt = executable instanceof Constructor && type == ScheduleData.class;
        if (!Modifier.isPublic(executable.getModifiers()) || exempt) {
          continue;
        }
        for (Type parameter : executable.getGenericParameterTypes()) {
          if (mentionsAPart(parameter)) {
            takers.add(executable.toGenericString());
          }
        }
      }
    }
    assertEquals(List.of(), takers);
  }

  // Generic parameters too, so a List<TimeOfDay> counts as taking a part.
  private static boolean mentionsAPart(Type type) {
    if (type instanceof Class<?> c) {
      Class<?> element = c.isArray() ? c.getComponentType() : c;
      return (element.getPackageName().equals("io.hron.ast") && !element.isEnum())
          || element == ScheduleData.class;
    }
    if (type instanceof ParameterizedType p) {
      return mentionsAPart(p.getRawType())
          || Arrays.stream(p.getActualTypeArguments()).anyMatch(PublicSurfaceTest::mentionsAPart);
    }
    if (type instanceof GenericArrayType g) {
      return mentionsAPart(g.getGenericComponentType());
    }
    if (type instanceof WildcardType w) {
      return Arrays.stream(w.getUpperBounds()).anyMatch(PublicSurfaceTest::mentionsAPart)
          || Arrays.stream(w.getLowerBounds()).anyMatch(PublicSurfaceTest::mentionsAPart);
    }
    return false;
  }

  @Test
  void ordinalPositionsNumberOneToFiveAndLastIsMinusOne() {
    Map<OrdinalPosition, Integer> expected =
        Map.of(
            OrdinalPosition.FIRST, 1,
            OrdinalPosition.SECOND, 2,
            OrdinalPosition.THIRD, 3,
            OrdinalPosition.FOURTH, 4,
            OrdinalPosition.FIFTH, 5,
            OrdinalPosition.LAST, -1);
    assertEquals(OrdinalPosition.values().length, expected.size());
    for (OrdinalPosition ordinal : OrdinalPosition.values()) {
      assertEquals(expected.get(ordinal), ordinal.toN(), ordinal.name());
    }
  }
}
