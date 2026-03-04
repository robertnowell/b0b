#!/usr/bin/env python3
"""Tests for deterministic transition logging in monitor.sh.

Validates:
  - extract_findings_block() parsing of structured audit/test output
  - get_audit_result() / get_test_result() 3-tuple return values
  - format_transition_slack() output formatting
  - Enriched findings entry format
  - Structured feedback composition for fixing agent
"""

import os
import pathlib
import re
import tempfile
import unittest


# ---------------------------------------------------------------------------
# Extract functions from monitor.sh's embedded Python
# ---------------------------------------------------------------------------

def _load_monitor_python():
    """Load all function defs from monitor.sh's embedded Python block."""
    monitor_path = pathlib.Path(__file__).with_name('monitor.sh')
    content = monitor_path.read_text()

    start_marker = "python3 -c \""
    start = content.find(start_marker)
    if start == -1:
        raise RuntimeError('Could not find python3 -c block in monitor.sh')
    start += len(start_marker)

    end_marker = '\n" "$SCRIPT_DIR"'
    end = content.find(end_marker, start)
    if end == -1:
        raise RuntimeError('Could not find end of python3 -c block in monitor.sh')

    return content[start:end].replace('\\"', '"').replace('\\\\', '\\')


def _load_function(func_name, end_marker):
    """Extract a single function from monitor.sh and compile it."""
    py_source = _load_monitor_python()
    start = py_source.find(f'def {func_name}(')
    if start == -1:
        raise RuntimeError(f'Could not find {func_name} in monitor.sh')

    end = py_source.find(end_marker, start + 1)
    if end == -1:
        raise RuntimeError(f'Could not find end marker for {func_name}')

    source = py_source[start:end]
    namespace = {'re': re, 'os': os, 'json': __import__('json')}
    exec(source, namespace)
    return namespace[func_name]


def _load_extract_findings_block():
    return _load_function('extract_findings_block', '\ndef get_audit_result(')


def _load_extract_structured_verdict():
    return _load_function('extract_structured_verdict', '\ndef extract_findings_block(')


def _load_format_transition_slack():
    return _load_function('format_transition_slack', '\n# --- API issue detection ---')


EXTRACT_FINDINGS_BLOCK = _load_extract_findings_block()
EXTRACT_STRUCTURED_VERDICT = _load_extract_structured_verdict()
FORMAT_TRANSITION_SLACK = _load_format_transition_slack()


def _load_get_audit_result():
    """Load get_audit_result with its dependencies injected."""
    py_source = _load_monitor_python()
    start = py_source.find('def get_audit_result(')
    end = py_source.find('\ndef get_test_result(', start)
    source = py_source[start:end]
    namespace = {
        're': re, 'os': os,
        'extract_structured_verdict': EXTRACT_STRUCTURED_VERDICT,
        'extract_findings_block': EXTRACT_FINDINGS_BLOCK,
    }
    exec(source, namespace)
    return namespace['get_audit_result']


def _load_get_test_result():
    """Load get_test_result with its dependencies injected."""
    py_source = _load_monitor_python()
    start = py_source.find('def get_test_result(')
    end = py_source.find('\ndef choose_audit_agent(', start)
    source = py_source[start:end]
    namespace = {
        're': re, 'os': os,
        'extract_structured_verdict': EXTRACT_STRUCTURED_VERDICT,
        'extract_findings_block': EXTRACT_FINDINGS_BLOCK,
    }
    exec(source, namespace)
    return namespace['get_test_result']


GET_AUDIT_RESULT = _load_get_audit_result()
GET_TEST_RESULT = _load_get_test_result()


# ---------------------------------------------------------------------------
# Section 1: extract_findings_block()
# ---------------------------------------------------------------------------

class TestExtractFindingsBlock(unittest.TestCase):
    def test_audit_block_parsed(self):
        content = (
            'Some output\n'
            'AUDIT_FINDINGS_START\n'
            'CRITICAL: 3\n'
            'MINOR: 1\n'
            'MISSING: error handling, input validation\n'
            'SUMMARY: Implementation lacks error boundaries\n'
            'AUDIT_FINDINGS_END\n'
            'AUDIT_VERDICT:FAIL\n'
        )
        result = EXTRACT_FINDINGS_BLOCK(content, 'AUDIT_FINDINGS')
        self.assertEqual(result['critical_count'], 3)
        self.assertEqual(result['minor_count'], 1)
        self.assertEqual(result['missing'], ['error handling', 'input validation'])
        self.assertEqual(result['summary'], 'Implementation lacks error boundaries')

    def test_test_block_with_status_fields(self):
        content = (
            'TEST_FINDINGS_START\n'
            'TESTS_PASSED: yes\n'
            'BUILD_PASSED: no\n'
            'LINT_PASSED: yes\n'
            'CRITICAL: 0\n'
            'MINOR: 2\n'
            'MISSING: none\n'
            'SUMMARY: Tests pass but build fails\n'
            'TEST_FINDINGS_END\n'
        )
        result = EXTRACT_FINDINGS_BLOCK(content, 'TEST_FINDINGS')
        self.assertTrue(result['tests_passed'])
        self.assertFalse(result['build_passed'])
        self.assertTrue(result['lint_passed'])
        self.assertEqual(result['critical_count'], 0)
        self.assertEqual(result['minor_count'], 2)
        self.assertEqual(result['missing'], [])
        self.assertEqual(result['summary'], 'Tests pass but build fails')

    def test_no_block_returns_empty(self):
        result = EXTRACT_FINDINGS_BLOCK('no block here', 'AUDIT_FINDINGS')
        self.assertEqual(result, {})

    def test_start_without_end_returns_empty(self):
        content = 'AUDIT_FINDINGS_START\nCRITICAL: 1\n'
        result = EXTRACT_FINDINGS_BLOCK(content, 'AUDIT_FINDINGS')
        self.assertEqual(result, {})

    def test_missing_none_is_empty_list(self):
        content = (
            'AUDIT_FINDINGS_START\n'
            'MISSING: none\n'
            'AUDIT_FINDINGS_END\n'
        )
        result = EXTRACT_FINDINGS_BLOCK(content, 'AUDIT_FINDINGS')
        self.assertEqual(result['missing'], [])

    def test_critical_zero_is_integer(self):
        content = (
            'AUDIT_FINDINGS_START\n'
            'CRITICAL: 0\n'
            'MINOR: 0\n'
            'AUDIT_FINDINGS_END\n'
        )
        result = EXTRACT_FINDINGS_BLOCK(content, 'AUDIT_FINDINGS')
        self.assertEqual(result['critical_count'], 0)
        self.assertIsInstance(result['critical_count'], int)
        self.assertEqual(result['minor_count'], 0)

    def test_multiple_blocks_uses_last(self):
        """rfind should pick the last START marker."""
        content = (
            'AUDIT_FINDINGS_START\n'
            'CRITICAL: 99\n'
            'AUDIT_FINDINGS_END\n'
            'some other output\n'
            'AUDIT_FINDINGS_START\n'
            'CRITICAL: 2\n'
            'AUDIT_FINDINGS_END\n'
        )
        result = EXTRACT_FINDINGS_BLOCK(content, 'AUDIT_FINDINGS')
        self.assertEqual(result['critical_count'], 2)

    def test_non_integer_critical_defaults_to_zero(self):
        content = (
            'AUDIT_FINDINGS_START\n'
            'CRITICAL: many\n'
            'AUDIT_FINDINGS_END\n'
        )
        result = EXTRACT_FINDINGS_BLOCK(content, 'AUDIT_FINDINGS')
        self.assertEqual(result['critical_count'], 0)


# ---------------------------------------------------------------------------
# Section 2: get_audit_result() / get_test_result() 3-tuple
# ---------------------------------------------------------------------------

class TestGetAuditResult(unittest.TestCase):
    def _write_log(self, content):
        """Write content to a temp file and return its path."""
        fd, path = tempfile.mkstemp(suffix='.log')
        with os.fdopen(fd, 'w') as f:
            f.write(content)
        self.addCleanup(os.unlink, path)
        return path

    def test_pass_with_findings_block(self):
        log = self._write_log(
            'Running audit...\n'
            'AUDIT_FINDINGS_START\n'
            'CRITICAL: 0\n'
            'MINOR: 0\n'
            'MISSING: none\n'
            'SUMMARY: All good\n'
            'AUDIT_FINDINGS_END\n'
            'AUDIT_VERDICT:PASS\n'
        )
        verdict, summary, findings = GET_AUDIT_RESULT({'logFile': log})
        self.assertEqual(verdict, 'pass')
        self.assertEqual(summary, 'All good')
        self.assertEqual(findings['critical_count'], 0)
        self.assertEqual(findings['missing'], [])

    def test_fail_with_findings_block(self):
        log = self._write_log(
            'AUDIT_FINDINGS_START\n'
            'CRITICAL: 2\n'
            'MINOR: 1\n'
            'MISSING: tests\n'
            'SUMMARY: Missing test coverage\n'
            'AUDIT_FINDINGS_END\n'
            'AUDIT_VERDICT:FAIL\n'
        )
        verdict, summary, findings = GET_AUDIT_RESULT({'logFile': log})
        self.assertEqual(verdict, 'fail')
        self.assertEqual(summary, 'Missing test coverage')
        self.assertEqual(findings['critical_count'], 2)

    def test_verdict_without_findings_block_backward_compat(self):
        log = self._write_log(
            'Some audit output\n'
            'Found issues with the code\n'
            'AUDIT_VERDICT:FAIL\n'
        )
        verdict, summary, findings = GET_AUDIT_RESULT({'logFile': log})
        self.assertEqual(verdict, 'fail')
        self.assertEqual(summary, 'Found issues with the code')
        self.assertEqual(findings, {})

    def test_no_verdict_defaults_to_fail(self):
        log = self._write_log('Just some output\nno verdict line\n')
        verdict, summary, findings = GET_AUDIT_RESULT({'logFile': log})
        self.assertEqual(verdict, 'fail')
        self.assertEqual(findings, {})

    def test_missing_log_file(self):
        verdict, summary, findings = GET_AUDIT_RESULT({'logFile': '/nonexistent/path.log'})
        self.assertEqual(verdict, 'unknown')
        self.assertIn('No log file', summary)
        self.assertEqual(findings, {})

    def test_empty_log_file_field(self):
        verdict, summary, findings = GET_AUDIT_RESULT({})
        self.assertEqual(verdict, 'unknown')
        self.assertEqual(findings, {})

    def test_summary_prefers_structured_over_fallback(self):
        log = self._write_log(
            'AUDIT_FINDINGS_START\n'
            'SUMMARY: Structured summary here\n'
            'AUDIT_FINDINGS_END\n'
            'This is the last non-agent line\n'
            'AUDIT_VERDICT:FAIL\n'
        )
        verdict, summary, findings = GET_AUDIT_RESULT({'logFile': log})
        self.assertEqual(summary, 'Structured summary here')


class TestGetTestResult(unittest.TestCase):
    def _write_log(self, content):
        fd, path = tempfile.mkstemp(suffix='.log')
        with os.fdopen(fd, 'w') as f:
            f.write(content)
        self.addCleanup(os.unlink, path)
        return path

    def test_pass_with_findings(self):
        log = self._write_log(
            'TEST_FINDINGS_START\n'
            'TESTS_PASSED: yes\n'
            'BUILD_PASSED: yes\n'
            'LINT_PASSED: yes\n'
            'CRITICAL: 0\n'
            'MINOR: 0\n'
            'MISSING: none\n'
            'SUMMARY: All tests pass\n'
            'TEST_FINDINGS_END\n'
            'TEST_VERDICT:PASS\n'
        )
        verdict, summary, findings = GET_TEST_RESULT({'logFile': log})
        self.assertEqual(verdict, 'pass')
        self.assertEqual(summary, 'All tests pass')
        self.assertTrue(findings['tests_passed'])
        self.assertTrue(findings['build_passed'])

    def test_fail_with_findings(self):
        log = self._write_log(
            'TEST_FINDINGS_START\n'
            'TESTS_PASSED: no\n'
            'BUILD_PASSED: yes\n'
            'LINT_PASSED: no\n'
            'CRITICAL: 1\n'
            'MINOR: 0\n'
            'MISSING: none\n'
            'SUMMARY: 3 tests failing\n'
            'TEST_FINDINGS_END\n'
            'TEST_VERDICT:FAIL\n'
        )
        verdict, summary, findings = GET_TEST_RESULT({'logFile': log})
        self.assertEqual(verdict, 'fail')
        self.assertFalse(findings['tests_passed'])
        self.assertTrue(findings['build_passed'])
        self.assertEqual(findings['critical_count'], 1)

    def test_missing_log(self):
        verdict, summary, findings = GET_TEST_RESULT({})
        self.assertEqual(verdict, 'unknown')
        self.assertEqual(findings, {})


# ---------------------------------------------------------------------------
# Section 3: format_transition_slack()
# ---------------------------------------------------------------------------

class TestFormatTransitionSlack(unittest.TestCase):
    def _make_entry(self, **overrides):
        entry = {
            'task_id': 'feat-x',
            'from_phase': 'auditing',
            'to_phase': 'fixing',
            'iteration': 2,
            'max_iterations': 4,
            'verdict': 'fail',
            'structured_findings': {
                'critical_count': 3,
                'minor_count': 1,
                'missing': ['error handling'],
                'summary': 'Implementation lacks error boundaries',
            },
            'input': {
                'prompt_template': 'fix-feedback.md',
                'prompt_size_bytes': 4300,
                'plan_size_bytes': 2400,
                'image_count': 0,
                'image_files': [],
            },
            'context_forwarded': {
                'feedback_source': 'log_tail_200',
                'feedback_size_bytes': 8100,
                'findings_carried': 2,
            },
        }
        entry.update(overrides)
        return entry

    def test_header_line(self):
        msg = FORMAT_TRANSITION_SLACK(self._make_entry())
        lines = msg.split('\n')
        self.assertEqual(lines[0], 'Transition: auditing -> fixing | feat-x | iter 2/4')

    def test_elapsed_shown(self):
        msg = FORMAT_TRANSITION_SLACK(self._make_entry(), elapsed='5m 30s')
        self.assertIn('Elapsed: 5m 30s', msg)

    def test_input_line_includes_plan_prompt_findings(self):
        msg = FORMAT_TRANSITION_SLACK(self._make_entry())
        self.assertIn('plan (2.3kb)', msg)
        self.assertIn('prompt (4.2kb)', msg)
        self.assertIn('2 prior findings', msg)

    def test_images_shown_when_present(self):
        entry = self._make_entry()
        entry['input']['image_count'] = 3
        msg = FORMAT_TRANSITION_SLACK(entry)
        self.assertIn('3 images', msg)

    def test_images_hidden_when_zero(self):
        entry = self._make_entry()
        entry['input']['image_count'] = 0
        msg = FORMAT_TRANSITION_SLACK(entry)
        self.assertNotIn('images', msg)

    def test_verdict_fail(self):
        msg = FORMAT_TRANSITION_SLACK(self._make_entry())
        self.assertIn('Output: FAIL', msg)

    def test_verdict_pass(self):
        entry = self._make_entry(verdict='pass')
        msg = FORMAT_TRANSITION_SLACK(entry)
        self.assertIn('Output: PASS', msg)

    def test_structured_findings_detail(self):
        msg = FORMAT_TRANSITION_SLACK(self._make_entry())
        self.assertIn('3 critical, 1 minor', msg)
        self.assertIn('Missing: error handling', msg)
        self.assertIn('Implementation lacks error boundaries', msg)

    def test_context_forwarded(self):
        msg = FORMAT_TRANSITION_SLACK(self._make_entry())
        self.assertIn('Context -> fixing:', msg)
        self.assertIn('feedback (7.9kb)', msg)
        self.assertIn('via log_tail_200', msg)

    def test_template_shown(self):
        msg = FORMAT_TRANSITION_SLACK(self._make_entry())
        self.assertIn('Template: fix-feedback.md', msg)

    def test_no_input_line_when_empty(self):
        entry = self._make_entry()
        entry['input'] = {'prompt_template': '', 'prompt_size_bytes': 0, 'plan_size_bytes': 0, 'image_count': 0}
        entry['context_forwarded'] = {'findings_carried': 0, 'feedback_size_bytes': 0, 'feedback_source': ''}
        msg = FORMAT_TRANSITION_SLACK(entry)
        self.assertNotIn('Input:', msg)

    def test_test_status_fields(self):
        entry = self._make_entry()
        entry['structured_findings'] = {
            'tests_passed': True,
            'build_passed': False,
        }
        msg = FORMAT_TRANSITION_SLACK(entry)
        self.assertIn('tests=pass', msg)
        self.assertIn('build=fail', msg)


# ---------------------------------------------------------------------------
# Section 4: Enriched findings entry format
# ---------------------------------------------------------------------------

def build_audit_finding_entry(iteration, audit_result, audit_summary, audit_findings):
    """Simulate the enriched finding entry logic from monitor.sh auditing handler."""
    entry = f'Audit #{iteration + 1}: {audit_result.upper()}'
    if audit_findings.get('critical_count') is not None or audit_findings.get('minor_count') is not None:
        entry += f' ({audit_findings.get("critical_count", 0)}C/{audit_findings.get("minor_count", 0)}m)'
    if audit_findings.get('summary'):
        entry += f' -- {audit_findings["summary"][:200]}'
    elif audit_summary:
        entry += f' -- {audit_summary[:200]}'
    return entry


def build_test_finding_entry(iteration, test_result, test_summary, test_findings):
    """Simulate the enriched test finding entry logic from monitor.sh testing handler."""
    entry = f'Test #{iteration + 1}: {test_result.upper()}'
    if test_findings.get('critical_count') is not None or test_findings.get('minor_count') is not None:
        entry += f' ({test_findings.get("critical_count", 0)}C/{test_findings.get("minor_count", 0)}m)'
    status = []
    if test_findings.get('tests_passed') is not None:
        status.append(f'tests={"pass" if test_findings["tests_passed"] else "fail"}')
    if test_findings.get('build_passed') is not None:
        status.append(f'build={"pass" if test_findings["build_passed"] else "fail"}')
    if status:
        entry += f' [{"  ".join(status)}]'
    if test_findings.get('summary'):
        entry += f' -- {test_findings["summary"][:200]}'
    elif test_summary:
        entry += f' -- {test_summary[:200]}'
    return entry


class TestEnrichedFindingsEntry(unittest.TestCase):
    def test_audit_fail_with_findings(self):
        entry = build_audit_finding_entry(0, 'fail', '', {
            'critical_count': 3, 'minor_count': 1,
            'summary': 'Missing error handling for edge cases'
        })
        self.assertEqual(entry, 'Audit #1: FAIL (3C/1m) -- Missing error handling for edge cases')

    def test_audit_pass_with_findings(self):
        entry = build_audit_finding_entry(0, 'pass', '', {
            'critical_count': 0, 'minor_count': 0,
            'summary': 'All good'
        })
        self.assertEqual(entry, 'Audit #1: PASS (0C/0m) -- All good')

    def test_audit_fail_without_findings_block(self):
        entry = build_audit_finding_entry(0, 'fail', 'last line fallback', {})
        self.assertEqual(entry, 'Audit #1: FAIL -- last line fallback')

    def test_audit_fail_no_summary_no_fallback(self):
        entry = build_audit_finding_entry(0, 'fail', '', {})
        self.assertEqual(entry, 'Audit #1: FAIL')

    def test_test_with_status_fields(self):
        entry = build_test_finding_entry(1, 'fail', '', {
            'critical_count': 1, 'minor_count': 0,
            'tests_passed': True, 'build_passed': False,
            'summary': 'Build broken'
        })
        self.assertIn('Test #2: FAIL', entry)
        self.assertIn('(1C/0m)', entry)
        self.assertIn('[tests=pass  build=fail]', entry)
        self.assertIn('-- Build broken', entry)

    def test_summary_truncated_at_200(self):
        long_summary = 'x' * 300
        entry = build_audit_finding_entry(0, 'fail', '', {
            'critical_count': 1, 'minor_count': 0,
            'summary': long_summary
        })
        self.assertIn('x' * 200, entry)
        self.assertNotIn('x' * 201, entry)


# ---------------------------------------------------------------------------
# Section 5: Structured feedback composition
# ---------------------------------------------------------------------------

def build_structured_feedback(structured_findings, log_lines=None):
    """Simulate the structured feedback composition from spawn_agent() fixing phase."""
    structured = structured_findings or {}
    structured_header = ''
    if structured:
        parts = []
        cc = structured.get('critical_count')
        mc = structured.get('minor_count')
        if cc is not None or mc is not None:
            parts.append(f'Issues: {cc or 0} critical, {mc or 0} minor')
        missing = structured.get('missing', [])
        if missing:
            parts.append('Missing:\n' + '\n'.join(f'- {m}' for m in missing))
        summary = structured.get('summary', '')
        if summary:
            parts.append(f'Assessment: {summary}')
        tp = structured.get('tests_passed')
        bp = structured.get('build_passed')
        lp = structured.get('lint_passed')
        if tp is not None or bp is not None or lp is not None:
            status_parts = []
            if tp is not None:
                status_parts.append(f'tests={"pass" if tp else "fail"}')
            if bp is not None:
                status_parts.append(f'build={"pass" if bp else "fail"}')
            if lp is not None:
                status_parts.append(f'lint={"pass" if lp else "fail"}')
            parts.append('Status: ' + ', '.join(status_parts))
        if parts:
            structured_header = '## Structured Assessment Summary\n' + '\n'.join(parts) + '\n\n'

    if log_lines is not None:
        tail_lines = log_lines[-200:] if len(log_lines) > 200 else log_lines
        return structured_header + '## Raw Log (last 200 lines)\n' + ''.join(tail_lines)
    elif structured_header:
        return structured_header
    return 'No previous findings.'


class TestStructuredFeedback(unittest.TestCase):
    def test_with_structured_findings(self):
        feedback = build_structured_feedback(
            {'critical_count': 2, 'minor_count': 1,
             'missing': ['input validation'],
             'summary': 'Needs error handling'},
            log_lines=['line 1\n', 'line 2\n']
        )
        self.assertTrue(feedback.startswith('## Structured Assessment Summary'))
        self.assertIn('Issues: 2 critical, 1 minor', feedback)
        self.assertIn('- input validation', feedback)
        self.assertIn('Assessment: Needs error handling', feedback)
        self.assertIn('## Raw Log (last 200 lines)', feedback)
        self.assertIn('line 1', feedback)

    def test_empty_findings_raw_tail_only(self):
        feedback = build_structured_feedback({}, log_lines=['raw line\n'])
        self.assertNotIn('Structured Assessment', feedback)
        self.assertIn('## Raw Log (last 200 lines)', feedback)
        self.assertIn('raw line', feedback)

    def test_no_log_no_findings(self):
        feedback = build_structured_feedback({})
        self.assertEqual(feedback, 'No previous findings.')

    def test_structured_without_log(self):
        feedback = build_structured_feedback(
            {'critical_count': 1, 'minor_count': 0, 'summary': 'Issue found'}
        )
        self.assertIn('## Structured Assessment Summary', feedback)
        self.assertNotIn('Raw Log', feedback)

    def test_test_status_fields_in_feedback(self):
        feedback = build_structured_feedback(
            {'tests_passed': False, 'build_passed': True, 'lint_passed': True,
             'critical_count': 1, 'minor_count': 0, 'summary': 'Test failure'},
            log_lines=['output\n']
        )
        self.assertIn('Status: tests=fail, build=pass, lint=pass', feedback)


if __name__ == '__main__':
    unittest.main()
