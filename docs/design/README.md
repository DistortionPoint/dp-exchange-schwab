# Design Documentation

Welcome to the design documentation for `dp_exchange_core`. This section is the collaborative workspace between the architect and Claude for iterative design, from initial concept through implementation planning. The conventions here are shared across the DpExchange package family and were adopted from `dp_crypto_management`.

## Design Workflow Process

The design workflow follows a structured, iterative approach that enables effective collaboration between the architect and Claude:

### 1. Design Initiation

- User identifies a feature, enhancement, or architectural change
- Initial design document is created using the standard template
- Design objectives and scope are clearly defined

### 2. Collaborative Design

- Iterative refinement through discussion and documentation updates
- Design approach and methodology are developed
- Implementation details are progressively elaborated

### 3. Implementation Planning

- Detailed implementation plan with subtasks
- Dependencies and prerequisites identification
- Code samples and prototypes development

### 4. Review and Iteration

- Regular review cycles with feedback incorporation
- Progress tracking through subtask checklists
- Design evolution documentation

### 5. Implementation Handoff

- Final design approval and sign-off
- Transition from design to development phase
- Implementation tracking and validation

## Document Structure

### Design Documents

Design documents follow a standardized structure and naming convention:

**Naming Convention**: `YYYY-MM-DD_design-topic-name.md`

- Date stamp for chronological tracking
- Descriptive topic name using kebab-case
- Examples:
  - `2025-06-02_user-authentication-system.md`
  - `2025-06-02_portfolio-dashboard-redesign.md`
  - `2025-06-02_api-rate-limiting-strategy.md`

### Code Samples

Code samples are organized in subdirectories matching their design documents:

**Directory Convention**: `YYYY-MM-DD_design-topic-name/`

- Matches the main design document name exactly
- Contains all code samples, prototypes, and examples
- Includes its own README.md for organization

## Directory Structure

```
docs/design/
├── README.md                           # This file - workflow overview + status convention
├── templates/                          # Document and structure templates
│   ├── design-document-template.md     # Standard design document template
│   └── code-samples-readme-template.md # Template for code sample directories
├── workflow/                           # Process documentation
│   ├── collaboration-process.md        # User-Claude collaboration guidelines
│   ├── naming-conventions.md           # Detailed naming standards
│   └── iteration-cycles.md             # Review and iteration process
├── ideas/                              # Non-blocking discoveries (idea docs)
│   └── <topic>.md                      # No date prefix; deleted when work lands
├── closed/                             # Historical archive — completed plans
│   ├── README.md                       # Explains archive-only purpose
│   └── YYYY-MM-DD_topic-name.md        # Same filenames, preserved chronology
│       + YYYY-MM-DD_topic-name/        # Matching code samples directory moves too
└── [Active Design Documents]           # Open plans currently being worked on
    ├── YYYY-MM-DD_design-topic-name.md
    └── YYYY-MM-DD_design-topic-name/   # Matching code samples directory
        ├── README.md
        └── [code samples...]
```

## Status Convention (added 2026-05-27)

Every active design document carries a `**Status**:` header at the top. Allowed values:

| Status | Meaning |
|---|---|
| `Draft` | Initial draft; not yet ready for architect review |
| `In Review` | Architect reviewing; may iterate |
| `Approved` | Architect signed off; execution can begin |
| `Implementing` | Phase work in progress |
| `Implemented` | All checklist items done AND closed retrospective written → **MOVE to `closed/`** |

### Closing a plan (mandatory routine)

When a plan reaches `Implemented` status (all checklist items done AND a closed
retrospective is appended to the doc), the LLM or architect MUST move it as part of
the close:

```
git mv docs/design/YYYY-MM-DD_topic.md docs/design/closed/
git mv docs/design/YYYY-MM-DD_topic/    docs/design/closed/    # if code-samples dir exists
```

Filenames stay date-prefixed (preserves chronology and prior inbound links). The
architect's scan of `docs/design/` should always show only open work — the queue of
plans that still need attention. The `closed/` archive is read-only history.

The proactive analysis loop (Phase 8 of multi-strategy orchestration plan) flags any
doc in `docs/design/` with status=`Implemented` that hasn't been moved.

### Idea docs (non-blocking discoveries)

Live in `docs/design/ideas/<topic>.md` (no date prefix). Created by the LLM when
a need is discovered but not yet acted on. Deleted when the work lands (per the
project's idea-doc lifecycle convention). When an idea is promoted to a dated plan
doc, the idea doc is deleted as part of executing the plan.

## Getting Started

### Creating a New Design Document

1. **Choose a descriptive topic name** following kebab-case convention
2. **Use current date** in YYYY-MM-DD format
3. **Copy the design document template** from [`templates/design-document-template.md`](./templates/design-document-template.md)
4. **Create matching code samples directory** if needed
5. **Follow the collaborative process** outlined in [`workflow/collaboration-process.md`](./workflow/collaboration-process.md)

### Naming Guidelines

- **Be descriptive**: Topic names should clearly indicate the design focus
- **Use kebab-case**: Lowercase with hyphens (e.g., `user-authentication-system`)
- **Include scope**: Indicate whether it's a feature, system, component, etc.
- **Avoid abbreviations**: Use full words for clarity

### Code Sample Organization

- **Group by feature/component**: Organize samples logically within directories
- **Use descriptive filenames**: Clear indication of sample purpose
- **Include documentation**: Each code sample directory needs a README.md
- **Version control**: Track iterations and changes within samples

## Integration with Other Documentation

Design documents integrate with the broader documentation ecosystem:

- **Architecture**: Design decisions feed into architectural documentation
- **Development**: Implementation plans guide development documentation
- **API**: API designs are documented in both design and API sections
- **User**: User experience designs inform user documentation

## Best Practices

### Design Document Quality

- **Clear objectives**: Always start with well-defined goals
- **Iterative refinement**: Embrace the collaborative process
- **Comprehensive planning**: Include all necessary implementation details
- **Progress tracking**: Use subtask checklists effectively

### Collaboration Effectiveness

- **Regular reviews**: Schedule consistent iteration cycles
- **Clear communication**: Document all decisions and rationale
- **Version tracking**: Maintain history of design evolution
- **Stakeholder alignment**: Ensure all parties understand the design

### Code Sample Standards

- **Working examples**: All samples should be functional
- **Clear documentation**: Explain purpose and usage
- **Consistent style**: Follow project coding standards
- **Incremental complexity**: Build from simple to complex examples

## Quick Reference

### Template Files

- [Design Document Template](./templates/design-document-template.md)
- [Code Samples README Template](./templates/code-samples-readme-template.md)

### Process Documentation

- [Collaboration Process](./workflow/collaboration-process.md)
- [Naming Conventions](./workflow/naming-conventions.md)
- [Iteration Cycles](./workflow/iteration-cycles.md)

### Examples

- See existing design documents for real-world examples
- Follow established patterns for consistency
- Reference successful designs for best practices

---

_This design documentation structure supports the iterative, collaborative approach between the architect and Claude, ensuring comprehensive design coverage from concept to implementation._
