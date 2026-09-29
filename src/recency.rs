//! Recency: which agent families had a real state transition, and the rank prefix that says so.
//!
//! Activity is a rise of Herdr's per-agent `state_change_seq`, compared between snapshots taken
//! by the subscriber. Output, focus, display and this plugin's own metadata writes never move
//! it. The only recency state is the subscriber's in-memory sequence map; the published
//! `agent_tree_rank` prefixes are the durable record and are read back on every pass.
//!
//! Stamps use the local wall clock. Each machine stamps its own transitions, so two
//! near-simultaneous transitions on machines whose clocks disagree can be ordered by the skew.

use crate::forest::Placement;
use crate::transport::Model;
use crate::wire::R;
use std::collections::{HashMap, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

/// Width of the inverted-time prefix, and the prefix of a family that has never been active.
/// It is the largest 13-digit value, so a neutral family sorts after every stamped one.
const PREFIX_WIDTH: usize = 13;
pub const NEUTRAL: u64 = 9_999_999_999_999;

/// Sequence memory of one subscriber process. The first observation is a neutral baseline.
#[derive(Clone, Debug, Default)]
pub struct Activity {
    seen: HashMap<String, u64>,
    baselined: bool,
}

impl Activity {
    /// Panes whose agent had a real state transition since the previous observation.
    ///
    /// A terminal first seen after the baseline is a new agent and counts; a sequence that is
    /// equal or lower does not. Every agent row must carry `terminal_id` and
    /// `state_change_seq`; otherwise nothing is recorded and the error names the pane.
    pub fn observe(&mut self, model: &Model) -> R<HashSet<String>> {
        let mut seen = HashMap::new();
        let mut active = HashSet::new();
        for row in model.ordered_rows().into_iter().filter(|r| !r.cleanup_only) {
            let (Some(terminal), Some(seq)) = (row.terminal_id.as_ref(), row.state_change_seq)
            else {
                return Err(format!(
                    "agent pane {} has no terminal_id/state_change_seq; recency unavailable",
                    row.pane_id
                ));
            };
            if self.baselined && self.seen.get(terminal).map_or(true, |old| seq > *old) {
                active.insert(row.pane_id.clone());
            }
            seen.insert(terminal.clone(), seq);
        }
        self.seen = seen;
        self.baselined = true;
        Ok(active)
    }
}

/// Inverted wall-clock milliseconds: ascending order is newest first.
pub fn inverted_now() -> R<u64> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock is before the Unix epoch: {e}"))?
        .as_millis();
    u64::try_from(millis)
        .ok()
        .filter(|millis| *millis < NEUTRAL)
        .map(|millis| NEUTRAL - millis)
        .ok_or_else(|| "system clock is outside the 13-digit recency range".to_string())
}

pub fn format_rank(inverted: u64, endpoint_prefix: &str, preorder: u32) -> String {
    format!("{inverted:0PREFIX_WIDTH$}-{endpoint_prefix}-{preorder:06}")
}

fn digits(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| b.is_ascii_digit())
}

fn endpoint(text: &str) -> bool {
    text.len() == 17
        && text.starts_with('h')
        && text[1..]
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Reads the recency out of a published rank. `Ok(None)` is neutral: only the exact v0.3.0
/// format `h<16 hex>-<6 digits>` is accepted as such. Anything else that is not the current
/// `<13 digits>-h<16 hex>-<6 digits>` format is an error naming the pane.
fn parse_rank(pane_id: &str, token: &str) -> R<Option<u64>> {
    let parts: Vec<&str> = token.split('-').collect();
    match parts.as_slice() {
        [endpoint_part, preorder] if endpoint(endpoint_part) && digits(preorder, 6) => Ok(None),
        [stamp, endpoint_part, preorder]
            if digits(stamp, PREFIX_WIDTH) && endpoint(endpoint_part) && digits(preorder, 6) =>
        {
            Ok(stamp.parse().ok())
        }
        _ => Err(format!(
            "pane {pane_id} carries a malformed agent_tree_rank {token:?}; \
             clear it (agent-tree.clear) to recover"
        )),
    }
}

/// Recency prefix of every family: the newest stamp already published on any member, moved to
/// `now_inverted` when a member was active in this pass. Families with neither are absent
/// (neutral). This reads the published tokens; there is no second store.
pub fn family_stamps(
    model: &Model,
    placements: &[Placement],
    active: &HashSet<String>,
    now_inverted: u64,
) -> R<HashMap<String, u64>> {
    let mut stamps: HashMap<String, u64> = HashMap::new();
    for placement in placements {
        let mut candidate = None;
        if let Some(token) = model
            .rows
            .get(&placement.pane_id)
            .and_then(|row| row.token(crate::projection::RANK_TOKEN))
        {
            candidate = parse_rank(&placement.pane_id, &token)?;
        }
        if active.contains(&placement.pane_id) {
            candidate = Some(candidate.map_or(now_inverted, |c| c.min(now_inverted)));
        }
        if let Some(candidate) = candidate {
            let entry = stamps
                .entry(placement.family_root.clone())
                .or_insert(candidate);
            *entry = (*entry).min(candidate);
        }
    }
    Ok(stamps)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{self, with_token};
    use crate::transport::{AgentRow, Model};

    fn model(rows: Vec<AgentRow>) -> Model {
        let mut model = Model::default();
        model.install(rows);
        model
    }

    fn with_seq(mut row: AgentRow, seq: u64) -> AgentRow {
        row.state_change_seq = Some(seq);
        row
    }

    fn placement(pane_id: &str, root: &str) -> Placement {
        Placement {
            pane_id: pane_id.to_string(),
            depth: usize::from(pane_id != root),
            is_last_sibling: true,
            role: String::new(),
            rank: 1,
            family_root: root.to_string(),
        }
    }

    fn ranked(pane_id: &str, token: &str) -> AgentRow {
        with_token(
            testutil::pi_row(pane_id, &format!("/s/{pane_id}")),
            crate::projection::RANK_TOKEN,
            token,
        )
    }

    const LEGACY: &str = "h0123456789abcdef-000004";
    const NEW: &str = "9999999990000-h0123456789abcdef-000004";

    #[test]
    fn only_a_sequence_rise_after_the_baseline_is_activity() {
        let row = |seq| vec![with_seq(testutil::pi_row("a", "/s/a"), seq)];
        let mut activity = Activity::default();
        assert!(activity.observe(&model(row(5))).unwrap().is_empty());
        assert!(activity.observe(&model(row(5))).unwrap().is_empty());
        assert!(activity.observe(&model(row(4))).unwrap().is_empty());
        let rose = activity.observe(&model(row(6))).unwrap();
        assert_eq!(rose, HashSet::from(["a".to_string()]));
        assert!(activity.observe(&model(row(6))).unwrap().is_empty());
    }

    #[test]
    fn a_new_agent_after_the_baseline_counts_but_the_baseline_itself_does_not() {
        let mut activity = Activity::default();
        let first = model(vec![testutil::pi_row("a", "/s/a")]);
        assert!(activity.observe(&first).unwrap().is_empty());
        let second = model(vec![
            testutil::pi_row("a", "/s/a"),
            testutil::other_row("codex"),
        ]);
        assert_eq!(
            activity.observe(&second).unwrap(),
            HashSet::from(["codex".to_string()])
        );
    }

    #[test]
    fn missing_sequence_data_is_an_error_naming_the_pane_and_records_nothing() {
        let mut activity = Activity::default();
        let mut bad = testutil::pi_row("broken", "/s/broken");
        bad.state_change_seq = None;
        let error = activity
            .observe(&model(vec![testutil::pi_row("a", "/s/a"), bad]))
            .unwrap_err();
        assert!(error.contains("broken"), "{error}");
        assert!(
            !activity.baselined,
            "a failed observation is not a baseline"
        );
    }

    #[test]
    fn newer_stamps_sort_first_and_a_family_shares_its_newest_prefix() {
        assert!(format_rank(10, "h0123456789abcdef", 9) < format_rank(11, "h0123456789abcdef", 1));
        assert_eq!(
            format_rank(NEUTRAL - 1_700_000_000_000, "h0123456789abcdef", 3),
            "8299999999999-h0123456789abcdef-000003"
        );

        // A child rise promotes the root's whole family; an older family keeps its stamp.
        let model = model(vec![
            ranked("root", "9999999990100-h0123456789abcdef-000001"),
            ranked("child", "9999999990200-h0123456789abcdef-000002"),
            ranked("other", "9999999990150-h0123456789abcdef-000003"),
        ]);
        let placements = [
            placement("root", "root"),
            placement("child", "root"),
            placement("other", "other"),
        ];
        let active = HashSet::from(["child".to_string()]);
        let stamps = family_stamps(&model, &placements, &active, 9_999_999_990_050).unwrap();
        assert_eq!(stamps["root"], 9_999_999_990_050);
        assert_eq!(stamps["other"], 9_999_999_990_150);
        // No activity: the newest published member prefix is read back for the whole family.
        let stamps = family_stamps(&model, &placements, &HashSet::new(), 0).unwrap();
        assert_eq!(stamps["root"], 9_999_999_990_100);
    }

    #[test]
    fn exact_v030_ranks_are_neutral_and_malformed_current_ranks_name_the_pane() {
        let placements = [placement("p", "p")];
        let stamps = |token: &str| {
            family_stamps(
                &model(vec![ranked("p", token)]),
                &placements,
                &HashSet::new(),
                0,
            )
        };
        assert!(stamps(LEGACY).unwrap().is_empty(), "legacy is neutral");
        assert_eq!(stamps(NEW).unwrap()["p"], 9_999_999_990_000);
        for bad in [
            "000001",
            "h0123456789abcdef-0001",
            "H0123456789ABCDEF-000004",
            "999999999000-h0123456789abcdef-000004",
            "9999999990000-h0123456789abcde-000004",
            "9999999990000-h0123456789abcdef-00004x",
            "9999999990000-h0123456789abcdef-000004-x",
            "",
        ] {
            let error = stamps(bad).unwrap_err();
            assert!(error.contains("pane p"), "{bad:?}: {error}");
        }
    }
}
