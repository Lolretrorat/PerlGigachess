# PerlGigachess Function Complexity Review (2026-02-16)

## Scope
Reviewed functions in:
- `Chess/Engine.pm`
- `Chess/State.pm`
- `Chess/TableUtil.pm`
- `Chess/Book.pm`
- `Chess/EndgameTable.pm`
- `Chess/LocationModifer.pm`
- `play.pl`
- `lichess.pl`
- `tests/perft.pl`
- `tests/regression_hyhMjQD2_kg8.pl`
- `scripts/build_opening_book.pl`
- `scripts/merge_opening_book.pl`
- `scripts/probe_syzygy.pl`

## Complexity Notation
- `N`: board squares (`64` in chess; represented on a 120-array board internally)
- `b`: branching factor (legal/pseudo-legal moves per node)
- `d`: search depth
- `M`: move count for a position (typically bounded, but variable)
- `E`, `G`, `T`, `S`: input-dependent sizes (entries/games/tokens/stream size)

## Top Priority Hotspots (Highest Practical ROI)
1. `Chess/Engine.pm:_search` and `_quiesce` (`O(b^d)` / `O(b^dq)`) dominate runtime.
2. `Chess/Engine.pm:_ordered_moves` (`O(b log b)` per node) and `_move_order_score` in hot loops.
3. `Chess/EndgameTable.pm:_legal_move_details` (`O(M^2)`) from nested move generation.
4. `Chess/LocationModifer.pm:_process_game_lines` and `_san_to_move` (`O(G*T*M)` / `O(M)` per SAN token).
5. `lichess.pl:_read_line` (byte-by-byte `sysread`) and related socket readers.

---

## `Chess/Engine.pm`
- `new` (`Chess/Engine.pm:112`) — `O(1)` — Suggestion: none required; minor micro-optimization would be centralizing defaults.
- `_normalize_location_modifiers` (`Chess/Engine.pm:169`) — `O(P*S)` — Suggestion: cache normalized tables once.
- `_clamp` (`Chess/Engine.pm:186`) — `O(1)` — Suggestion: none needed.
- `_location_modifier_percent` (`Chess/Engine.pm:193`) — `O(1)` — Suggestion: direct map piece->table ref to reduce lookups.
- `_location_bonus` (`Chess/Engine.pm:200`) — `O(1)` — Suggestion: skip when modifiers disabled/zero.
- `_flip_idx` (`Chess/Engine.pm:207`) — `O(1)` — Suggestion: optional precomputed index map.
- `_rank_of_idx` (`Chess/Engine.pm:214`) — `O(1)` — Suggestion: optional lookup table.
- `_file_of_idx` (`Chess/Engine.pm:219`) — `O(1)` — Suggestion: optional lookup table.
- `_is_square_attacked_by_side` (`Chess/Engine.pm:224`) — `O(1)` bounded ray scans — Suggestion: cache attack maps per node.
- `_find_piece_idx` (`Chess/Engine.pm:274`) — `O(N)` — Suggestion: track king/piece indices incrementally.
- `_is_passed_pawn` (`Chess/Engine.pm:282`) — `O(N)` bounded by files/ranks — Suggestion: pawn-structure cache or masks.
- `_development_score` (`Chess/Engine.pm:308`) — `O(N)` — Suggestion: fuse with other eval passes / cached piece data.
- `_passed_pawn_score` (`Chess/Engine.pm:357`) — `O(N^2)` effective due repeated passer checks — Suggestion: one-pass pawn eval.
- `_hanging_piece_score` (`Chess/Engine.pm:381`) — `O(N)` with heavy attack checks — Suggestion: reuse precomputed attack maps.
- `_is_quiet_hanging_move` (`Chess/Engine.pm:408`) — `O(1)` — Suggestion: feed cached attack info.
- `_hanging_move_penalty` (`Chess/Engine.pm:426`) — `O(1)` — Suggestion: none needed.
- `_king_ring_indices` (`Chess/Engine.pm:436`) — `O(1)` — Suggestion: precompute ring per square.
- `_king_danger_for_piece` (`Chess/Engine.pm:449`) — `O(N)` — Suggestion: share attack/pawn-shield data.
- `_king_danger_score` (`Chess/Engine.pm:498`) — `O(N)` — Suggestion: compute both sides in one shared pass.
- `_non_king_piece_count` (`Chess/Engine.pm:505`) — `O(N)` — Suggestion: keep piece counts in state metadata.
- `_king_aggression_for_piece` (`Chess/Engine.pm:519`) — `O(1)` — Suggestion: none needed.
- `_king_aggression_score` (`Chess/Engine.pm:527`) — `O(N)` — Suggestion: reuse piece-count pass.
- `_is_king_safety_critical_move` (`Chess/Engine.pm:536`) — `O(1)` — Suggestion: pass cached king square/ring.
- `_is_tactical_queen_move` (`Chess/Engine.pm:559`) — `O(1)` — Suggestion: cached enemy king ring/attacks.
- `_unsafe_capture_penalty` (`Chess/Engine.pm:582`) — `O(1)` to `O(N)` (if danger recompute) — Suggestion: avoid recomputing king danger inside hot path.
- `_ordered_moves` (`Chess/Engine.pm:619`) — `O(b log b)` — Suggestion: partial sort / staged ordering.
- `_move_order_score` (`Chess/Engine.pm:628`) — `O(1)` each, hot — Suggestion: inline small bonuses and reduce key allocations.
- `_is_capture_state` (`Chess/Engine.pm:674`) — `O(1)` — Suggestion: annotate capture flag in generated move.
- `_move_key` (`Chess/Engine.pm:690`) — `O(1)` — Suggestion: pack to numeric key to avoid string churn.
- `_history_bonus` (`Chess/Engine.pm:695`) — `O(1)` — Suggestion: array-indexed history if using compact keys.
- `_killer_bonus` (`Chess/Engine.pm:700`) — `O(1)` — Suggestion: numeric killer keys.
- `_countermove_bonus` (`Chess/Engine.pm:709`) — `O(1)` — Suggestion: compact index map for counter-moves.
- `_store_killer` (`Chess/Engine.pm:717`) — `O(1)` — Suggestion: reuse computed key once.
- `_store_countermove` (`Chess/Engine.pm:726`) — `O(1)` — Suggestion: none needed.
- `_update_history` (`Chess/Engine.pm:732`) — `O(1)` — Suggestion: compact integer indexing.
- `_decay_history` (`Chess/Engine.pm:738`) — `O(H)` history table size — Suggestion: lazy decay scheme.
- `_trim_transposition_table` (`Chess/Engine.pm:745`) — `O(T)` TT size — Suggestion: cheaper eviction policy than full scan.
- `_piece_count` (`Chess/Engine.pm:767`) — `O(N)` — Suggestion: maintain count incrementally.
- `_is_middlegame_piece_count` (`Chess/Engine.pm:779`) — `O(1)` — Suggestion: none needed.
- `_is_pawn_move_in_state` (`Chess/Engine.pm:786`) — `O(1)` — Suggestion: include piece-type flag in move struct.
- `_configure_time_limits` (`Chess/Engine.pm:795`) — `O(1)` — Suggestion: table-driven policy refactor for simpler hot-path logic.
- `_time_up_soft` (`Chess/Engine.pm:933`) — `O(1)` — Suggestion: none needed.
- `_extend_soft_deadline` (`Chess/Engine.pm:937`) — `O(1)` — Suggestion: none needed.
- `_check_time_or_abort` (`Chess/Engine.pm:947`) — amortized `O(1)` — Suggestion: tune check interval dynamically.
- `_state_key` (`Chess/Engine.pm:954`) — depends on FEN serialization (`~O(N)`) — Suggestion: cache canonical key in state.
- `_find_move_by_key` (`Chess/Engine.pm:959`) — `O(b)` — Suggestion: index generated moves by key once.
- `_quiesce` (`Chess/Engine.pm:972`) — `O(b^dq)` — Suggestion: stricter capture ordering/filtering.
- `_evaluate_board` (`Chess/Engine.pm:1013`) — effective multiple board scans (`~O(N^2)` with nested helpers) — Suggestion: fuse eval components / incremental eval.
- `_search` (`Chess/Engine.pm:1039`) — `O(b^d)` — Suggestion: prioritize TT reuse, reduce allocation in move ordering, and strengthen cutoffs.
- `think` (`Chess/Engine.pm:1183`) — iterative deepening over `_search` — Suggestion: avoid repeated policy recompute per iteration where possible.

## `Chess/State.pm`
- `new` (`Chess/State.pm:18`) — `O(1)` — Suggestion: none needed.
- `set_fen` (`Chess/State.pm:36`) — `O(1)` on fixed board — Suggestion: replace per-char regex with direct lookup checks.
- `get_fen` (`Chess/State.pm:120`) — `O(1)` — Suggestion: none needed.
- `get_board` (`Chess/State.pm:177`) — `O(1)` — Suggestion: none needed.
- `get_moves` (`Chess/State.pm:192`) — `O(M * make_move_cost)` — Suggestion: inherits `generate_moves` cost.
- `encode_move` (`Chess/State.pm:200`) — `O(1)` — Suggestion: none needed.
- `decode_move` (`Chess/State.pm:232`) — `O(1)` — Suggestion: none needed.
- `_square_to_idx` (`Chess/State.pm:254`) — `O(1)` — Suggestion: none needed.
- `_idx_to_square` (`Chess/State.pm:264`) — `O(1)` — Suggestion: none needed.
- `_flip_idx` (`Chess/State.pm:273`) — `O(1)` — Suggestion: none needed.
- `make_move` (`Chess/State.pm:281`) — `O(1)` fixed-size copy/check — Suggestion: consider make/unmake in-place for heavy legality filtering.
- `generate_moves` (`Chess/State.pm:374`) — `O(M * make_move_cost)` — Suggestion: lighter legality check with reversible in-place updates.
- `is_checked` (`Chess/State.pm:384`) — `O(1)` — Suggestion: none needed.
- `is_playable` (`Chess/State.pm:388`) — depends on `generate_moves` — Suggestion: none beyond move-gen improvements.
- `checked` (`Chess/State.pm:392`) — `O(1)` fixed scan — Suggestion: track king index directly.
- `attacked` (`Chess/State.pm:401`) — `O(1)` bounded rays/offsets — Suggestion: none needed.
- `generate_pseudo_moves` (`Chess/State.pm:442`) — `O(1)` bounded by board size — Suggestion: centralize/precompute piece vectors to cut branching.
- `pp` (`Chess/State.pm:544`) — `O(1)` — Suggestion: none needed.

## `Chess/TableUtil.pm`
- `canonical_fen_key` (`Chess/TableUtil.pm:18`) — `O(1)` (`~O(N)` serialization) — Suggestion: cache per-state if called repeatedly in same node.
- `relaxed_fen_key` (`Chess/TableUtil.pm:25`) — `O(1)` — Suggestion: none needed.
- `normalize_uci_move` (`Chess/TableUtil.pm:33`) — `O(1)` — Suggestion: none needed.
- `merge_weighted_moves` (`Chess/TableUtil.pm:45`) — `O((N+M) log(N+M))` — Suggestion: keep hash-backed canonical aggregation and avoid full re-sort on every merge.
- `idx_to_square` (`Chess/TableUtil.pm:97`) — `O(1)` — Suggestion: none needed.
- `board_indices` (`Chess/TableUtil.pm:106`) — `O(1)` — Suggestion: none needed.
- `_build_board_indices` (`Chess/TableUtil.pm:110`) — `O(1)` startup — Suggestion: none needed.

## `Chess/Book.pm`
- `_book_path` (`Chess/Book.pm:40`) — `O(1)` — Suggestion: cache path once.
- `_load_json_book` (`Chess/Book.pm:46`) — `O(E*M log M)` — Suggestion: lazy/conditional reload; avoid full rebuild each load.
- `choose_move` (`Chess/Book.pm:77`) — `O(M + E log E)` — Suggestion: memoize legal map and normalized keys per state.
- `_lookup_fen_move` (`Chess/Book.pm:82`) — `O(M + E)` (+ ranking) — Suggestion: index entries by normalized UCI.
- `_legal_move_map` (`Chess/Book.pm:107`) — `O(M)` — Suggestion: cache map on state key.
- `_legacy_lookup` (`Chess/Book.pm:121`) — `O(1)` — Suggestion: none needed.
- `_parse_book_moves` (`Chess/Book.pm:131`) — `O(k)` per entry — Suggestion: parse/validate once.
- `_merge_book_entries` (`Chess/Book.pm:171`) — `O(P log P)` — Suggestion: defer sorting until finalization.
- `_rank_legal_entries` (`Chess/Book.pm:210`) — `O(N log N)` — Suggestion: prefilter by `played` and/or top-k before full sort.
- `_select_ranked_entry` (`Chess/Book.pm:247`) — `O(N)` — Suggestion: reuse precomputed played/quality fields.
- `_entry_played` (`Chess/Book.pm:265`) — `O(1)` — Suggestion: none needed.
- `_entry_quality_for_side` (`Chess/Book.pm:273`) — `O(1)` — Suggestion: cache in ranking pass.
- `_entry_rank` (`Chess/Book.pm:286`) — `O(1)` — Suggestion: none needed.
- `_is_sparse_move` (`Chess/Book.pm:293`) — `O(1)` — Suggestion: none needed.
- `_book_rank_weights` (`Chess/Book.pm:301`) — `O(1)` — Suggestion: none needed.
- `_side_to_move` (`Chess/Book.pm:315`) — `O(1)` — Suggestion: none needed.
- `_positive_num` (`Chess/Book.pm:323`) — `O(1)` — Suggestion: none needed.
- `_nonneg_num` (`Chess/Book.pm:333`) — `O(1)` — Suggestion: none needed.
- `_env_int` (`Chess/Book.pm:343`) — `O(1)` — Suggestion: memoize env reads.
- `_env_num` (`Chess/Book.pm:352`) — `O(1)` — Suggestion: memoize env reads.
- `_pick_weighted` (`Chess/Book.pm:362`) — `O(N)` — Suggestion: prefix sums for repeated sampling.

## `Chess/EndgameTable.pm`
- `_table_path` (`Chess/EndgameTable.pm:31`) — `O(1)` — Suggestion: none needed.
- `_load_tables` (`Chess/EndgameTable.pm:37`) — `O(E*M log M)` — Suggestion: lazy load and avoid repeated merges.
- `choose_move` (`Chess/EndgameTable.pm:101`) — up to `O(M^2 + E)` via `_legal_move_details` — Suggestion: shared legal-detail cache.
- `tablebase_entries` (`Chess/EndgameTable.pm:126`) — `O(M + P log P + probe_latency)` — Suggestion: stronger probe cache/TTL and batching.
- `_choose_ranked_table_move` (`Chess/EndgameTable.pm:202`) — `O(E + M)` (+ detail cost) — Suggestion: consume precomputed details.
- `_choose_simple_mating_move` (`Chess/EndgameTable.pm:233`) — `O(M)` — Suggestion: none needed.
- `_is_basic_mating_material` (`Chess/EndgameTable.pm:257`) — `O(1)` — Suggestion: none needed.
- `_legal_move_details` (`Chess/EndgameTable.pm:291`) — `O(M^2)` — Suggestion: cache per-candidate opponent move counts / early exits.
- `_probe_syzygy` (`Chess/EndgameTable.pm:321`) — dominated by external process I/O — Suggestion: persistent probe worker.
- `_probe_script_path` (`Chess/EndgameTable.pm:347`) — `O(1)` — Suggestion: none needed.
- `_syzygy_paths` (`Chess/EndgameTable.pm:356`) — `O(P)` — Suggestion: cache parsed paths.
- `_piece_count` (`Chess/EndgameTable.pm:376`) — `O(64)` — Suggestion: optional incremental count.
- `_env_bool` (`Chess/EndgameTable.pm:393`) — `O(1)` — Suggestion: memoize env reads.
- `_env_int` (`Chess/EndgameTable.pm:402`) — `O(1)` — Suggestion: memoize env reads.
- `_numeric_or` (`Chess/EndgameTable.pm:412`) — `O(1)` — Suggestion: none needed.
- `_maybe_numeric` (`Chess/EndgameTable.pm:418`) — `O(1)` — Suggestion: none needed.
- `_in_syzygy_failure_backoff` (`Chess/EndgameTable.pm:425`) — `O(1)` — Suggestion: none needed.
- `_mark_syzygy_failure` (`Chess/EndgameTable.pm:431`) — `O(1)` — Suggestion: none needed.

## `Chess/LocationModifer.pm`
- `_empty_square_table` (`Chess/LocationModifer.pm:17`) — `O(64)` — Suggestion: build once and clone shallowly if needed.
- `default_store_path` (`Chess/LocationModifer.pm:80`) — `O(1)` — Suggestion: none needed.
- `load_from_file` (`Chess/LocationModifer.pm:90`) — `O(S)` file size — Suggestion: avoid reload if unchanged.
- `save_to_file` (`Chess/LocationModifer.pm:110`) — `O(S)` — Suggestion: none needed.
- `train_from_stream` (`Chess/LocationModifer.pm:122`) — `O(G*T*M)` — Suggestion: sample/limit games and reuse SAN conversion caches.
- `_apply_external_preferences` (`Chess/LocationModifer.pm:165`) — `O(P*64)` — Suggestion: none needed.
- `_process_game_lines` (`Chess/LocationModifer.pm:182`) — `O(T*M)` per game — Suggestion: faster PGN parser and cached SAN->move mapping.
- `_clean_pgn_body` (`Chess/LocationModifer.pm:248`) — `O(n)` — Suggestion: combine regex passes where possible.
- `_san_to_move` (`Chess/LocationModifer.pm:259`) — `O(M)` per token — Suggestion: precompute SAN index from generated moves.
- `_find_castle_move` (`Chess/LocationModifer.pm:334`) — `O(M)` — Suggestion: none needed.
- `_apply_counts` (`Chess/LocationModifer.pm:343`) — `O(P*64)` — Suggestion: none needed.
- `_sync_opponent_modifiers` (`Chess/LocationModifer.pm:366`) — `O(P*64)` — Suggestion: none needed.
- `_piece_key` (`Chess/LocationModifer.pm:377`) — `O(1)` — Suggestion: none needed.

## `play.pl`
- `run_interactive` (`play.pl:44`) — per turn cost dominated by engine search — Suggestion: cache legal-move list between unchanged states.
- `run_uci` (`play.pl:95`) — command loop with search-heavy `go` — Suggestion: avoid redundant `_record_position` recomputation.
- `print_board` (`play.pl:217`) — `O(1)` fixed 8x8 print — Suggestion: verbose gating if needed.
- `_record_position` (`play.pl:235`) — `~O(N)` via FEN key generation — Suggestion: memoize key for identical state.
- `_current_draw_status` (`play.pl:242`) — `O(1)` — Suggestion: none needed.
- `_normalize_depth` (`play.pl:262`) — `O(1)` — Suggestion: none needed.
- `_parse_go_command` (`play.pl:271`) — `O(tokens)` — Suggestion: dispatch-table parser for fewer branches.

## `lichess.pl`
- `main` (`lichess.pl:77`) — setup + stream loop — Suggestion: none critical.
- `stream_events` (`lichess.pl:100`) — `O(events + reconnects)` — Suggestion: exponential backoff.
- `reap_children` (`lichess.pl:120`) — `O(children)` — Suggestion: none needed.
- `run_dry_run` (`lichess.pl:128`) — linear in scripted events — Suggestion: dedupe challenge handling earlier.
- `handle_event` (`lichess.pl:261`) — `O(1)` dispatch — Suggestion: none needed.
- `log_finished_game_url` (`lichess.pl:286`) — `O(log_lines)` due duplicate scan — Suggestion: in-memory seen-set to avoid rescans.
- `maybe_log_finished_from_status` (`lichess.pl:375`) — `O(1)` — Suggestion: none.
- `is_terminal_game_status` (`lichess.pl:382`) — `O(1)` — Suggestion: none.
- `ensure_parent_dir` (`lichess.pl:391`) — `O(path_depth)` — Suggestion: none.
- `game_url_from_payload` (`lichess.pl:408`) — `O(1)` — Suggestion: none.
- `normalize_lichess_url` (`lichess.pl:420`) — `O(1)` — Suggestion: none.
- `handle_challenge` (`lichess.pl:428`) — `O(1)` — Suggestion: normalize/lc once.
- `challenge_id` (`lichess.pl:498`) — `O(1)` — Suggestion: none.
- `extract_challenge_payload` (`lichess.pl:508`) — `O(depth)` nested payload depth — Suggestion: none.
- `accept_challenge` (`lichess.pl:523`) — bounded retries + network — Suggestion: jittered retry sleeps.
- `decline_challenge` (`lichess.pl:550`) — network-bound — Suggestion: none.
- `start_game` (`lichess.pl:561`) — `O(1)` + fork cost — Suggestion: process pooling only if concurrency grows.
- `play_game` (`lichess.pl:577`) — stream/event-loop dominated — Suggestion: add network stall timeout guards.
- `handle_game_event` (`lichess.pl:639`) — `O(1)` + delegates — Suggestion: coalesce redundant updates.
- `parse_moves` (`lichess.pl:684`) — `O(move_tokens)` — Suggestion: none.
- `normalize_color` (`lichess.pl:691`) — `O(1)` — Suggestion: none.
- `normalize_fen` (`lichess.pl:700`) — `O(1)` — Suggestion: none.
- `normalize_speed` (`lichess.pl:706`) — `O(1)` — Suggestion: none.
- `extract_speed` (`lichess.pl:713`) — `O(1)` — Suggestion: none.
- `extract_turn_flag` (`lichess.pl:724`) — `O(1)` — Suggestion: none.
- `update_turn_from_event` (`lichess.pl:739`) — `O(1)` — Suggestion: none.
- `infer_turn_from_moves` (`lichess.pl:749`) — `O(move_count)` — Suggestion: rely on incremental turn flag when possible.
- `initial_side_from_fen` (`lichess.pl:763`) — `O(1)` — Suggestion: none.
- `maybe_move` (`lichess.pl:772`) — roughly `O(L + C^2)` with retries/candidates — Suggestion: skip contender expansion when bestmove is legal.
- `_sync_state_from_game` (`lichess.pl:830`) — `O(new_moves)` incremental replay — Suggestion: persist/reuse synced state aggressively.
- `_candidate_moves` (`lichess.pl:883`) — `O(L + P)` — Suggestion: reuse contender list when unchanged.
- `_engine_contender_moves` (`lichess.pl:915`) — `O(P log P + generation)` — Suggestion: tighter candidate cap.
- `_is_retryable_illegal_reject` (`lichess.pl:944`) — `O(1)` — Suggestion: none.
- `maybe_apply_speed_depth` (`lichess.pl:954`) — `O(lines_until_readyok)` — Suggestion: timeout on engine stall.
- `_format_eval_suffix` (`lichess.pl:989`) — `O(1)` — Suggestion: none.
- `compute_bestmove` (`lichess.pl:1004`) — engine/network-bound — Suggestion: none beyond early break on `bestmove`.
- `send_move` (`lichess.pl:1066`) — network-bound — Suggestion: none.
- `uci_handshake` (`lichess.pl:1090`) — `O(lines)` — Suggestion: timeout protection.
- `lichess_json_get` (`lichess.pl:1135`) — network-bound — Suggestion: none.
- `log_info` (`lichess.pl:1142`) — `O(1)` — Suggestion: none.
- `log_warn` (`lichess.pl:1147`) — `O(1)` — Suggestion: none.
- `log_debug` (`lichess.pl:1152`) — `O(1)` — Suggestion: none.
- `_emit_log` (`lichess.pl:1158`) — `O(1)` — Suggestion: none.
- `_drain_ndjson` (`lichess.pl:1164`) — `O(buffered_lines)` — Suggestion: keep streaming parse, avoid duplicate decode attempts.
- `_read_http_headers` (`lichess.pl:1184`) — `O(header_count)` — Suggestion: none.
- `_consume_chunked` (`lichess.pl:1204`) — `O(chunks + bytes)` — Suggestion: larger buffered reads.
- `_read_line` (`lichess.pl:1222`) — `O(line_length)` with bytewise syscall loop — Suggestion: buffered block read parser (high ROI).
- `_read_exact` (`lichess.pl:1235`) — `O(len)` — Suggestion: larger chunk reads.
- `_read_all` (`lichess.pl:1247`) — `O(total_bytes)` — Suggestion: none.
- `load_env` (`lichess.pl:1259`) — `O(env_lines)` — Suggestion: timestamp-based reload guard if called often.
- `_open_lichess_socket` (`lichess.pl:1276`) — network retry-bound — Suggestion: reuse DNS/socket/session when possible.
- `_write_http_request` (`lichess.pl:1347`) — `O(headers + body)` — Suggestion: none.
- `http_request` (`lichess.pl:1361`) — network dominated — Suggestion: persistent keep-alive connections.
- `_encode_form` (`lichess.pl:1440`) — `O(K log K)` key sort — Suggestion: skip sorting where ordering not required.
- `_encode_query` (`lichess.pl:1450`) — `O(K log K)` — Suggestion: same.
- `_form_escape` (`lichess.pl:1460`) — `O(len)` — Suggestion: none.
- `_query_escape` (`lichess.pl:1468`) — `O(len)` — Suggestion: none.
- `stream_ndjson` (`lichess.pl:1475`) — `O(events + reconnects)` — Suggestion: reuse request template and improve buffer strategy.

## `tests/perft.pl`
- `rec_perft` (`tests/perft.pl:32`) — `O(b^d)` — Suggestion: optional TT/Zobrist memoization for duplicate subtree reuse in validation runs.

## `tests/regression_hyhMjQD2_kg8.pl`
- `send_cmd` (`tests/regression_hyhMjQD2_kg8.pl:29`) — `O(1)` — Suggestion: none.
- `read_until` (`tests/regression_hyhMjQD2_kg8.pl:34`) — `O(lines_until_match)` — Suggestion: add timeout guard.

## `scripts/build_opening_book.pl`
- `_merge_existing_output` (`scripts/build_opening_book.pl:173`) — `O(E*M)` — Suggestion: stream-merge large files instead of full decode when data grows.
- `_nonneg_num` (`scripts/build_opening_book.pl:231`) — `O(1)` — Suggestion: none.
- `_entry_total_played` (`scripts/build_opening_book.pl:240`) — `O(M)` — Suggestion: none.
- `_report_progress` (`scripts/build_opening_book.pl:249`) — `O(1)` — Suggestion: none.
- `_open_pgn_handle` (`scripts/build_opening_book.pl:256`) — `O(1)` + process startup — Suggestion: reuse compressor path checks.
- `_cmd_exists` (`scripts/build_opening_book.pl:276`) — `O(PATH_entries)` — Suggestion: memoize command existence.
- `_consume_games` (`scripts/build_opening_book.pl:287`) — `O(games + lines)` — Suggestion: avoid repeated regex churn on separators.
- `_process_game` (`scripts/build_opening_book.pl:321`) — `O(plies * SAN_resolution)` — Suggestion: cache SAN-to-move by position key.
- `_parse_elo` (`scripts/build_opening_book.pl:411`) — `O(1)` — Suggestion: none.
- `_tokenize_movetext` (`scripts/build_opening_book.pl:418`) — `O(chars)` — Suggestion: none unless profiling shows hotspot.
- `_san_to_candidate` (`scripts/build_opening_book.pl:479`) — `O(L*P)` worst-case — Suggestion: per-position SAN index cache.
- `_piece_to_san` (`scripts/build_opening_book.pl:563`) — `O(1)` — Suggestion: none.

## `scripts/merge_opening_book.pl`
- `_read_entries` (`scripts/merge_opening_book.pl:93`) — `O(file_size)` — Suggestion: stream parse if files become large.
- `_num` (`scripts/merge_opening_book.pl:112`) — `O(1)` — Suggestion: none.
- `_total_played` (`scripts/merge_opening_book.pl:118`) — `O(M)` — Suggestion: none.

## `scripts/probe_syzygy.pl`
- `_result` (`scripts/probe_syzygy.pl:10`) — `O(1)` — Suggestion: none.
- `_normalize_paths` (`scripts/probe_syzygy.pl:15`) — `O(P)` — Suggestion: none.
- `_category_from_wdl` (`scripts/probe_syzygy.pl:33`) — `O(1)` — Suggestion: none.
- `_resolve_probetool_path` (`scripts/probe_syzygy.pl:43`) — `O(candidate_paths)` — Suggestion: cache chosen path.
- `_wdl_from_meaning` (`scripts/probe_syzygy.pl:60`) — `O(1)` — Suggestion: none.
- `_probe_with_probetool` (`scripts/probe_syzygy.pl:83`) — dominated by external process startup/output parse — Suggestion: persistent worker process if probing frequently.
- `_probe_with_python` (`scripts/probe_syzygy.pl:166`) — `O(M * probes_per_move)` — Suggestion: probe WDL first; restrict DTZ probing to top candidates.

## Suggested Implementation Order
1. Engine hot-loop allocation/caching fixes: `_move_key` usage, `_ordered_moves`, `_move_order_score`, `_state_key` caching.
2. Endgame move-detail cache in `_legal_move_details`.
3. Buffered socket reader rewrite in `lichess.pl` (`_read_line`, `_read_exact`).
4. SAN resolution caches in `LocationModifer.pm` and `scripts/build_opening_book.pl`.
5. Optional incremental evaluation metadata in `Chess::State` for piece counts/king squares.
