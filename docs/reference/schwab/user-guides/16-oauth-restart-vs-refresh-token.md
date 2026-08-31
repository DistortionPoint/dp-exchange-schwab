# OAuth Restart vs. Refresh Token

Source: https://developer.schwab.com/user-guides/apis-and-apps/oauth-restart-vs-refresh-token
Captured: 2026-08-31 from the signed-in Schwab Developer Portal.

---

When do I need to restart the OAuth Flow vs. use the Refresh Token step?

Restarting the OAuth Flow:

When a property change to an OAuth token is needed, the entire Flow must be restarted from the beginning and the User's CAG completed through LMS once again. Other conditions may also exist that require this restart as well.

Below are some of the most common reasons to restart the Flow as opposed to using the Refresh Token step:

The refresh_token is compromised or malfunctioning.

Note:
A compromised or missing access_token can be resolved using the simple Refresh Token step.
This will not require the full restart.
A scope value is needed and was not requested for the current access_token.
A new access_token is needed when different User accounts need to be authorized.
This could originate from a mistake during the User CAG activities or from a necessary change in the authorized accounts or other Protected Resources selected.
The OAuth Flow was accidentally restarted and aborted, after the first Authorize an App step was completed.
This automatically invalidates the current access_token.
Restart the OAuth flow and be sure to complete it as normal.
A User revokes a token’s access manually, changes account credentials or modifies the TFA (Two-Factor Authentication) setup.
In this case, the User might be expecting involvement to authorize different accounts or consent to continued access after a credentials change.
The User is always in control of access to their Protected Resources at Schwab.
Revoking a token can be done at any time and should terminate third-party access unless it’s explicitly granted again.
Changes are made to security or other policies affecting protected resources or other Schwab assets.
This ensures that the User or third-party agrees to the modified Terms of Service (TOS) or other policies changes.
This case is the standard protocol and doesn’t result from risk mitigation or other security-related actions.
Technical difficulties with the Refresh Token functionality or endpoint access occur.
This could be a documented or unknown error and cause.
Technical support should be engaged to assist with debugging when other attempts fail.

Using the Refresh Token

Under normal circumstances, the Refresh Token functionality can be used to renew Third-Party Application access to Protected Resources. Even returning sessions can be authenticated by refreshing an expired token. The Refresh Token functionality is usually sufficient; however, in some situations this functionality will not be able to generate a token with the properties currently needed. These edge-cases may only occasionally be encountered.

Below are the conditions where the Refresh Token step should be sufficient to renew Protected Resource access:

An access_token has expired normally.
The token's lifetime is returned expressed in seconds in the "expires_in" parameter
The access_token has been lost but not compromised.
This can occur when application logic fails to store the value in a variable or other memory location.
A developer programmatically determines that an access_token will be refreshed to mitigate “401 Unauthorized” failures preemptively.
It is quite common for developers to program the automatic refresh of an access_token - even before it expired.
If this is not done excessively frequently, this should not place excess strain on the OAuth resources.
The benefit to refreshing before expiration is the mitigation of unnecessary “401” errors.

These errors are often encountered when an API call is placed near the time that an access_token would normally expire.
