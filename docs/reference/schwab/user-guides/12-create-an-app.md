# Create an App

Source: https://developer.schwab.com/user-guides/apis-and-apps/create-an-app
Captured: 2026-08-31 from the signed-in Schwab Developer Portal.

---

Apps allow your Company to interact with APIs. Once your Company has been granted access to an API Product, you can create a App.

Note:
Each Line of Business manages their own rules regarding the creation of apps. In some cases you may be required to create and test an app in the Sandbox Environment, then request approval to Promote that App to the Production Environment.

To Create an App:

Note:
You must either be a member of a company, or an Individual Developer and be approved to use the API Product.

Select Dashboard link in the main menu.
Select Apps from the navigation menu.
Select Create App.
Fill in App Name and Callback URL fields.
Select an API Product. This will subscribe your App to that API Product.
Submit.

App Field Guide

App Name is displayed to end users. Use a name that end users recognize and understand they will grant access to.

Callback URL is where end users will be returned to after authorizing your App access to data.

Some Lines of Business (LOBs) enforce restrictions to the URL protocol, such as requiring an HTTPS address, and may restrict special characters from being included in the callback URL field.
Multiple callback URLs are supported by separating each with a comma.
Field is restricted to 255 characters. Contact support if your URL exceeds limit.

App Approval and Status

Many API Products are configured to auto-approve Sandbox App creation. In cases where Sandbox Apps are not auto-approved, a Pending (approval) status will be displayed until approved.

App statuses you may experience include:

Pending- Awaiting Admin review and approval.

Sandbox - Approved Sandbox access. The App is ready for testing.

Rejected/Denied - App creation has not been approved. Contact Support for detail.

Upon successful creation and approval, the App’s Client ID and Client Secret will be found in the App Details.

Active (Approved) - The app has been approved and is available for use.

Inactive (Revoked) – The app has been disabled and will be unavailable for use until it has been re-activated.

Important:
App Key and Secret should be considered highly confidential and should only be used to authenticate your application and make requests to APIs.
