# Naming Conventions - Design Documentation

This document establishes comprehensive naming conventions for all design documentation, code samples, and related files in this project. Consistent naming ensures easy navigation, chronological tracking, and clear organization.

## Core Principles

### Consistency

- Use the same naming pattern across all design documents
- Apply conventions uniformly regardless of document size or complexity
- Maintain consistency between document names and directory names

### Clarity

- Names should clearly indicate the content and purpose
- Avoid abbreviations unless they are well-established and clear
- Use descriptive terms that will be understood by all team members

### Chronological Organization

- Include date stamps for temporal tracking
- Use ISO 8601 date format (YYYY-MM-DD) for universal compatibility
- Enable easy sorting and historical analysis

### Scalability

- Support growing number of design documents
- Allow for categorization and grouping
- Facilitate automated processing and tooling

## Design Document Naming

### Primary Format

```
YYYY-MM-DD_design-topic-name.md
```

### Components Breakdown

#### Date Component (YYYY-MM-DD)

- **Format**: ISO 8601 date format
- **Purpose**: Chronological tracking and sorting
- **Example**: `2025-06-02`
- **Rules**:
  - Always use 4-digit year
  - Always use 2-digit month (01-12)
  - Always use 2-digit day (01-31)
  - Use hyphens as separators

#### Topic Name Component

- **Format**: kebab-case (lowercase with hyphens)
- **Purpose**: Descriptive identification of design focus
- **Example**: `user-authentication-system`
- **Rules**:
  - Use lowercase letters only
  - Separate words with hyphens
  - No spaces, underscores, or special characters
  - Maximum 50 characters recommended
  - Minimum 10 characters for clarity

### Design Document Examples

#### Feature Designs

```
2025-06-02_user-authentication-system.md
2025-06-02_portfolio-dashboard-redesign.md
2025-06-02_real-time-price-notifications.md
2025-06-02_multi-currency-support.md
2025-06-02_advanced-charting-components.md
```

#### System Designs

```
2025-06-02_api-rate-limiting-strategy.md
2025-06-02_database-optimization-plan.md
2025-06-02_caching-architecture-design.md
2025-06-02_microservices-migration-plan.md
2025-06-02_security-audit-implementation.md
```

#### Integration Designs

```
2025-06-02_external-exchange-integration.md
2025-06-02_payment-gateway-integration.md
2025-06-02_third-party-analytics-setup.md
2025-06-02_blockchain-data-synchronization.md
2025-06-02_email-notification-service.md
```

#### UI/UX Designs

```
2025-06-02_mobile-responsive-layout.md
2025-06-02_accessibility-improvements.md
2025-06-02_dark-mode-implementation.md
2025-06-02_user-onboarding-flow.md
2025-06-02_dashboard-personalization.md
```

## Code Samples Directory Naming

### Primary Format

```
YYYY-MM-DD_design-topic-name/
```

### Rules

- **Exact match**: Directory name must exactly match the corresponding design document name (without .md extension)
- **Case sensitivity**: Maintain exact case matching
- **Character consistency**: Use identical characters and separators

### Examples

```
2025-06-02_user-authentication-system/
├── README.md
├── prototypes/
├── components/
└── services/

2025-06-02_portfolio-dashboard-redesign/
├── README.md
├── components/
├── styles/
└── assets/
```

## File Naming Within Code Sample Directories

### Elixir/Phoenix Files

#### Module Files

- **Format**: `snake_case.ex`
- **Examples**:
  ```
  user_authentication_service.ex
  portfolio_dashboard_controller.ex
  price_notification_worker.ex
  currency_conversion_helper.ex
  ```

#### Test Files

- **Format**: `snake_case_test.exs`
- **Examples**:
  ```
  user_authentication_service_test.exs
  portfolio_dashboard_controller_test.exs
  price_notification_worker_test.exs
  ```

#### Template Files

- **Format**: `snake_case.html.heex`
- **Examples**:
  ```
  user_dashboard.html.heex
  portfolio_summary.html.heex
  price_chart_component.html.heex
  ```

### Database Files

#### Migration Files

- **Format**: `YYYYMMDDHHMMSS_descriptive_name.exs`
- **Examples**:
  ```
  20250602120000_create_user_authentication_tables.exs
  20250602120100_add_portfolio_dashboard_fields.exs
  20250602120200_create_price_notification_settings.exs
  ```

#### Schema Files

- **Format**: `descriptive_name.sql`
- **Examples**:
  ```
  user_authentication_schema.sql
  portfolio_dashboard_schema.sql
  price_notification_schema.sql
  ```

### Configuration Files

#### Environment Files

- **Format**: `.env.example`, `.env.development`, `.env.production`
- **Examples**:
  ```
  .env.user_auth_example
  .env.portfolio_dashboard_dev
  .env.price_notifications_prod
  ```

#### Application Configuration

- **Format**: `feature_name_config.exs`
- **Examples**:
  ```
  user_authentication_config.exs
  portfolio_dashboard_config.exs
  price_notification_config.exs
  ```

### Frontend Files

#### Component Files

- **Format**: `PascalCase.ex` for LiveView components
- **Examples**:
  ```
  UserDashboard.ex
  PortfolioSummary.ex
  PriceChart.ex
  NotificationSettings.ex
  ```

#### Style Files

- **Format**: `kebab-case.css`
- **Examples**:
  ```
  user-dashboard.css
  portfolio-summary.css
  price-chart.css
  notification-settings.css
  ```

#### JavaScript Files

- **Format**: `kebab-case.js`
- **Examples**:
  ```
  user-dashboard.js
  portfolio-chart.js
  price-notifications.js
  ```

## Subdirectory Organization

### Standard Subdirectory Names

#### Within Code Sample Directories

```
prototypes/          # Early concept implementations
components/          # UI/Frontend components
services/           # Backend services and business logic
database/           # Database schemas and migrations
api/               # API controllers and endpoints
config/            # Configuration files and examples
tests/             # Test files and test data
docs/              # Additional documentation
assets/            # Images, icons, and media files
scripts/           # Utility scripts and tools
```

#### Within Prototype Directories

```
concept-a/          # First prototype approach
concept-b/          # Alternative prototype approach
final-prototype/    # Selected prototype for implementation
archived/          # Deprecated or unused prototypes
```

### Subdirectory Naming Rules

- Use lowercase with hyphens for multi-word names
- Keep names short but descriptive
- Use standard names consistently across projects
- Group related files logically

## Special Cases and Variations

### Version Iterations

When a design document needs major revisions:

```
2025-06-02_user-authentication-system.md      # Original
2025-06-15_user-authentication-system-v2.md   # Major revision
2025-06-30_user-authentication-system-v3.md   # Another major revision
```

### Related Designs

For closely related design documents:

```
2025-06-02_user-authentication-core.md
2025-06-02_user-authentication-oauth.md
2025-06-02_user-authentication-2fa.md
```

### Spike/Research Documents

For exploratory or research-focused designs:

```
2025-06-02_spike-blockchain-integration.md
2025-06-02_research-performance-optimization.md
2025-06-02_poc-real-time-websockets.md
```

### Architecture Decision Records (ADRs)

For architectural decisions:

```
2025-06-02_adr-database-selection.md
2025-06-02_adr-authentication-strategy.md
2025-06-02_adr-frontend-framework-choice.md
```

## Naming Validation

### Automated Checks

Consider implementing automated validation for:

- Date format correctness
- Topic name format compliance
- Directory/file name matching
- Character set restrictions

### Manual Review Checklist

- [ ] Date format is YYYY-MM-DD
- [ ] Topic name uses kebab-case
- [ ] No special characters or spaces
- [ ] Directory name matches document name
- [ ] File names follow established patterns
- [ ] Subdirectory names are consistent

## Migration Guidelines

### Existing Documents

When updating existing documents to follow new conventions:

1. **Create new document** with proper naming
2. **Copy content** from old document
3. **Update references** in other documents
4. **Archive old document** with clear redirect
5. **Update index** and navigation

### Bulk Renaming

For large-scale naming updates:

1. **Plan the migration** with clear mapping
2. **Update all references** before renaming
3. **Use version control** to track changes
4. **Test all links** and references
5. **Communicate changes** to team

## Tools and Automation

### Naming Helpers

Consider creating tools for:

- **Name generation**: Generate proper names from descriptions
- **Validation**: Check names against conventions
- **Migration**: Assist with bulk renaming operations
- **Index generation**: Automatically create document indexes

### Integration with Development Tools

- **IDE templates**: Create file templates with proper naming
- **Git hooks**: Validate naming on commit
- **CI/CD checks**: Automated naming validation
- **Documentation generators**: Auto-generate indexes and navigation

## Examples and Anti-Patterns

### Good Examples

```
✅ 2025-06-02_user-authentication-system.md
✅ 2025-06-02_portfolio-dashboard-redesign.md
✅ 2025-06-02_api-rate-limiting-strategy.md
✅ user_authentication_service.ex
✅ portfolio_dashboard_controller_test.exs
```

### Anti-Patterns to Avoid

```
❌ UserAuth.md                          # No date, wrong case
❌ 2025-6-2_user_auth.md               # Wrong date format, underscores
❌ 2025-06-02_User Authentication.md    # Spaces, wrong case
❌ design-user-auth-2025-06-02.md      # Wrong order
❌ UserAuthenticationService.ex         # Wrong case for file name
```

## Reference Quick Guide

### Design Document Template

```
YYYY-MM-DD_design-topic-name.md
```

### Code Sample Directory Template

```
YYYY-MM-DD_design-topic-name/
```

### Common File Extensions

- `.md` - Markdown documentation
- `.ex` - Elixir module files
- `.exs` - Elixir script files (tests, migrations)
- `.heex` - Phoenix HTML templates
- `.css` - Stylesheets
- `.js` - JavaScript files
- `.sql` - SQL schema files
- `.env` - Environment configuration

### Date Format Reference

- **Correct**: `2025-06-02`, `2025-12-31`, `2025-01-01`
- **Incorrect**: `2025-6-2`, `25-06-02`, `06-02-2025`

---

**Document Version**: 1.0  
**Last Updated**: 2025-06-02  
**Next Review**: 2025-09-02
