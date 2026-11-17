"""Finite-state design model, not an implementation of Runtime or the CLI."""
import unittest

# Event names describe confirmed observations, not requests or assumptions.
TRANSITIONS = {
    ('Prepared','start_recorded'):'Starting',
    ('Prepared','cancel_before_spawn'):'Cancelled',
    ('Starting','cancel_requested'):'CancelRequested',
    ('Starting','spawn_confirmed'):'Running',
    ('Starting','start_failure_confirmed'):'Failed',
    ('Starting','spawn_outcome_unknown'):'Unknown',
    ('Running','cancel_requested'):'CancelRequested',
    ('Running','normal_exit_confirmed'):'Succeeded',
    ('Running','failure_confirmed'):'Failed',
    ('Running','outcome_unknown'):'Unknown',
    ('Running','interruption_confirmed'):'Interrupted',
    ('CancelRequested','spawn_confirmed'):'CancelRequested',
    ('CancelRequested','cancel_exit_confirmed'):'Cancelled',
    ('CancelRequested','normal_exit_confirmed'):'Succeeded',
    ('CancelRequested','failure_confirmed'):'Failed',
    ('CancelRequested','interruption_confirmed'):'Interrupted',
    ('CancelRequested','outcome_unknown'):'Unknown',
    ('Unknown','live_process_identity_confirmed'):'Running',
    ('Unknown','normal_exit_confirmed'):'Succeeded',
    ('Unknown','failure_confirmed'):'Failed',
    ('Unknown','cancel_exit_confirmed'):'Cancelled',
    ('Unknown','interruption_confirmed'):'Interrupted',
}
TERMINAL={'Succeeded','Failed','Cancelled','Interrupted'}
EVENTS={event for _,event in TRANSITIONS}|{'retry','app_exit','success_assumed','cancel_requested'}

def move(state,event):
    try:return TRANSITIONS[(state,event)]
    except KeyError:raise ValueError('illegal transition')

def apply_sequence(events):
    state='Prepared'
    for event in events:state=move(state,event)
    return state

class LifecycleContract(unittest.TestCase):
    def test_valid_cancel_race_then_success(self):
        self.assertEqual('Succeeded',apply_sequence(['start_recorded','spawn_confirmed','cancel_requested','normal_exit_confirmed']))
    def test_cancel_before_spawn(self):
        self.assertEqual('Cancelled',apply_sequence(['cancel_before_spawn']))
    def test_uncertain_spawn_blocks_replay(self):
        state=apply_sequence(['start_recorded','spawn_outcome_unknown'])
        self.assertEqual('Unknown',state)
        with self.assertRaises(ValueError):move(state,'retry')
        with self.assertRaises(ValueError):move(state,'start_recorded')
        with self.assertRaises(ValueError):move(state,'success_assumed')
    def test_spawn_confirmed_after_cancel_remains_pending(self):
        state=apply_sequence(['start_recorded','cancel_requested','spawn_confirmed'])
        self.assertEqual('CancelRequested',state)

    def test_cancel_request_is_not_cancellation(self):
        self.assertEqual('CancelRequested',apply_sequence(['start_recorded','cancel_requested']))
    def test_unknown_resolution_requires_observation(self):
        state=apply_sequence(['start_recorded','spawn_outcome_unknown'])
        self.assertEqual('Running',move(state,'live_process_identity_confirmed'))
        self.assertEqual('Succeeded',move(state,'normal_exit_confirmed'))
        self.assertEqual('Interrupted',move(state,'interruption_confirmed'))
    def test_app_exit_never_means_process_exit(self):
        for state in ['Starting','Running','CancelRequested','Unknown']:
            with self.subTest(state=state):
                with self.assertRaises(ValueError):move(state,'app_exit')
    def test_all_terminal_states_are_immutable(self):
        for state in TERMINAL:
            for event in EVENTS:
                with self.subTest(state=state,event=event):
                    with self.assertRaises(ValueError):move(state,event)
    def test_failed_record_prevents_start(self):
        # A failed pre-start commit cannot produce the sole spawn-enabled state.
        with self.assertRaises(ValueError):move('Prepared','spawn_confirmed')
        with self.assertRaises(ValueError):move('Prepared','storage_failed_start_anyway')

if __name__=='__main__':unittest.main(verbosity=2)
