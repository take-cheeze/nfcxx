# frozen_string_literal: true

# CONSTANT_REVIEWED (docs/adr/0491): the engine constants the bc2cpp type check leaves untyped, read and reviewed.
# The gate (tools/bc2cpp/constant_reviewed.rb, TC1017) fails on an unlisted untyped constant and on a listed one
# that is typed or gone, so this list only shrinks. Regenerate with
# `MRBC=... ruby scripts/bc2cpp/constant_reviewed_update.rb --write`, after reading each added name's source.
require 'set'

CONSTANT_REVIEWED = Set[
  "Game::ChipSet::ALL_DIRS",
  "RPG2k::Scene::ChipsetEditor::BLOCKED_COLOR",
  "RPG2k::Scene::ChipsetEditor::CURSOR_COLOR",
  "RPG2k::Scene::ChipsetEditor::HINT_COLOR",
  "RPG2k::Scene::ChipsetEditor::PASSABLE_COLOR",
  "RPG2k::Scene::ChipsetEditor::TEXT_COLOR",
  "RPG2k::Scene::ChipsetEditor::UNKNOWN_COLOR",
  "RPG2k::Scene::MapViewer::BLOCKED_COLOR",
  "RPG2k::Scene::MapViewer::CURSOR_COLOR",
  "RPG2k::Scene::MapViewer::HINT_COLOR",
  "RPG2k::Scene::MapViewer::PASSABLE_COLOR",
  "RPG2k::Scene::MapViewer::TEXT_COLOR",
  "RPG2k::Scene::MapViewer::UNKNOWN_COLOR",
  "STDERR",
  "STDIN",
  "STDOUT",
].freeze
