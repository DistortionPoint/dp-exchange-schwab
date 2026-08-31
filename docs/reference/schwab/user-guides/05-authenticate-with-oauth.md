# Authenticate with OAuth

Source: https://developer.schwab.com/user-guides/get-started/authenticate-with-oauth
Captured: 2026-08-31 from the signed-in Schwab Developer Portal.

---

Schwab & API Security

Schwab is committed to providing the highest standards of digital security and privacy for our Clients. Using the OAuth 2 authorization framework, Schwab can provide secure, delegated access over HTTPS to devices, APIs, servers, and applications using access tokens in place of Client credentials.

 

OAuth 2 Overview

Schwab employs the OAuth 2 protocol to secure services from unauthorized access. OAuth 2 is the second iteration of this IETF traditional client-server authentication framework and a current standard for RESTful API security. Our implementation adheres to current IETF standards. This open standard framework operates over HTTPS, effectively replacing username+password with an encrypted token to access User data. Official IETF RFC articles may be found here:

OAuth 2 - https://tools.ietf.org/html/rfc6749
Bearer Token - https://tools.ietf.org/html/rfc6750

Bearer tokens are used for the OAuth authorization_code Grant Type.

 

Three-Legged Workflow

Three-Legged OAuth is a workflow (Flow) that allows Users to grant an App permission to access Protected Resources, such as their account information, without disclosing credentials. OAuth directs Users to Schwab's Login Micro Site (LMS) to perform the Consent and Grant (CAG) process. Here, the User may select and authorize the accounts they wish to be shared with the Third-Party Application (Application). Upon completion of the CAG process, the User is redirected back to the Application.

Key Terms

App

OAuth registration is managed by Apps on the Dev Portal. Here, these Apps are owned by a Company and used internally to manage Application access to Protected Resource data.

App elements and attributes include:

Client ID & Client Secret

These string values are unique to an App and are generated when it gets approved and registered with the OAuth server. When an App is authorized using the OAuth Flow, these elements help identify and control access that the App has to Protected Resources data going forward. Permissions to access an API Product are also tied to an App and its corresponding Client ID. The Client Secret will never be exposed outside of the OAuth Flow and App management in the Dev Portal. Client Secret values should always be kept confidential and stored securely by an Application.

Callback URL

OAuth uses the Callback URL ("redirect_uri") to redirect the User and OAuth Flow back to the Application when necessary. This will be used as the URL "host" of that Application's landing page:

Callback URLs must be HTTPS. There is a 255-character limit on this field including all URLs listed. Multiple URLs are supported by separating each with a comma.

Display Name

The Display Name is established when the App is created in the Dev Portal and shown on screen to the User performing CAG activities. This helps ensure that consent is granted to the appropriate App.

Environment

Apps may exist in either Sandbox (test data access) or the Production environment (live data access). See the “Creating an App” and “Promoting an App to Production” sections for more information.

Product Subscription

Apps may only subscribe to a single API Product, for example, Account Aggregation DDA.

Third-Party Application (User-Agent / "Application"):

This will represent any website, stand-alone application or other HTTP platform that uses an OAuth Bearer token to access Protected Resource data on behalf of a User.

Note: This is completely different than the “App” as defined here.

CAG - Consent and Grant

Using LMS, Schwab Users will provide their approval of Application access and select the accounts they wish to link.

LMS - Login Micro Site

A website for Users to log into Schwab directly from an Application to perform CAG activities.

LOB - Line of Business

Owner of an API Product or functional grouping of APIs in Schwab's Dev Portal. Examples: Data Aggregation Services, Tax Services, etc. Companies may request access to API Products owned by the LOB.

Roles

IETF's OAuth 2 framework defines four Roles, such as the Resource Owner (User), referenced throughout this OAuth documentation.

User

User is the Protected Resource Owner that authorizes Application access to their information. User may be referenced interchangeably with: a Schwab Client, the Resource Owner, End User, or App User.

More info?

Further IETF OAuth definition of Resource Owner can be found here: https://tools.ietf.org/html/rfc6749#section-1.1

Token

Several types of Tokens are used in OAuth 2 Flows. All Tokens are simply string values representing attributes such as scope, lifetime, and other information that is used for different purposes.

Access Token

To enhance API security, Apps will use an Access Token to access User's Protected Resources. This is used in place of their username+password combination.

Bearer Token

A Bearer token is the Access Token in the context of an API call for Protected Resource data. It is passed in the Authorization header as "Bearer {access_token_value}.

Refresh Token

The Refresh Token renews access to User’s Protected Resources. This may be done before, or at any point after the current, valid access_token expires. When it does expire, the corresponding Refresh Token is used to request a new Access Token as opposed to repeating the entire Flow. This token is provided along with the initial Access Token and should be stored for later use.

Three-Legged Flow Entities

The primary entities involved in the Three-Legged OAuth Flow are the following:

Resource Owner (User) - Schwab Client or User that owns and grants access to Protected Resources.
OAuth Client (App) - The App living in the Dev Portal. Using its Client ID and Client Secret, it requests access to Protected Resources on behalf of the User.
User-Agent (3rd-party application) - The Resource Owner will use this application, or website, to interact with Schwab APIs and access Protected Resources.
Authorization Server (OAuth server) - OAuth server that authenticates OAuth Clients and issues Tokens.
Resource Server - Schwab server that hosts our Users' Protected Resources, such as a financial account information.
OAuth Flow - Sequence Diagram
