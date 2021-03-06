setTestOpts([only_compiler_types(['ghc']),
             omit_ways(['ghci']),
             when(fast(), skip)])

test('hpc_help', normal, run_command, ["{hpc} help"])
test('hpc_help_help', normal, run_command, ["{hpc} help help"])

test('hpc_help_report', normal, run_command, ["{hpc} help report"])
test('hpc_report_001', normal, run_command,
     ["{hpc} report hpc_sample.tix --xml-output"])
test('hpc_report_002', normal, run_command,
     ["{hpc} report hpc_sample.tix --xml-output --per-module"])
test('hpc_report_003', normal, run_command,
     ["{hpc} report hpc_sample.tix --per-module --decl-list"])
test('hpc_report_error_001', exit_code(1), run_command,
     ["{hpc} report"]) # no .tix file
test('hpc_report_error_002', exit_code(1), run_command,
     ["{hpc} report hpc001.hs"]) # bad .tix file

test('hpc_help_markup', normal, run_command, ["{hpc} help markup"])
test('hpc_markup_error_001', exit_code(1), run_command,
     ["{hpc} markup"]) # no .tix file
test('hpc_markup_error_002', exit_code(1), run_command,
     ["{hpc} markup hpc001.hs"]) # bad .tix file
test('hpc_markup_001', normal, run_command,
     ["{hpc} markup hpc_sample.tix --highlight-covered; cat Main.hs.html"])
test('hpc_markup_002', normal, run_command,
     ["{hpc} markup hpc_sample.tix --fun-entry-count; cat Main.hs.html"])

test('hpc_help_show', normal, run_command, ["{hpc} help show"])
test('hpc_show', normal, run_command, ["{hpc} show hpc_sample.tix"])
test('hpc_show_error_001', exit_code(1), run_command,
     ["{hpc} show"]) # no .tix file
test('hpc_show_error_002', exit_code(1), run_command,
     ["{hpc} show hpc001.hs"]) # bad .tix file

test('hpc_help_version', normal, run_command, ["{hpc} help version"])
test('hpc_version', normal, run_command, ["{hpc} version"])

test('hpc_help_draft', normal, run_command, ["{hpc} help draft"])
test('hpc_draft', normal, run_command, ["{hpc} draft hpc_sample.tix"])

test('hpc_help_overlay', normal, run_command, ["{hpc} help overlay"])

test('hpc_overlay',
     [extra_clean(['sample_overlay1.tix', 'total1.tix'])],
     run_command,
     ["{hpc} overlay sample_overlay.ovr > sample_overlay1.tix; "
      "cat sample_overlay1.tix; "
      "{hpc} combine hpc_sample.tix sample_overlay1.tix > total1.tix; "
      "{hpc} report total1.tix"])

test('hpc_overlay2',
     [extra_clean(['sample_overlay2.tix', 'total2.tix'])],
     run_command,
     ["{hpc} overlay sample_overlay.ovr --output=sample_overlay2.tix; "
      "cat sample_overlay2.tix; "
      "{hpc} combine hpc_sample.tix sample_overlay2.tix --output=total2.tix; "
      "{hpc} report total2.tix"])

test('hpc_hand_overlay',
     [extra_clean(['sample_overlay3.tix', 'total3.tix'])],
     run_command,
     ["{hpc} overlay hand_overlay.ovr --output=sample_overlay3.tix; "
      "cat sample_overlay3.tix; "
      "{hpc} combine hpc_sample.tix sample_overlay3.tix --output=total3.tix; "
      "{hpc} report total3.tix"])

test('hpc_bad_001', exit_code(1), run_command, ["{hpc} bad arguments"])

test('T9619', ignore_output, run_command,
     # Having the same mix file in two different hpcdirs should work.
     ["{hpc} report hpc_sample.tix --hpcdir=.hpc --hpcdir=.hpc.copy"])
