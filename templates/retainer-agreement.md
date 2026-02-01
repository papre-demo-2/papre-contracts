# Retainer Services Agreement

**Agreement ID:** This Agreement is recorded on-chain upon execution.

**Effective Date:** {Effective Date: date: Date the agreement becomes effective}

---

## 1. Parties

This Retainer Services Agreement ("Agreement") is entered into by and between:

**Client:**
- Company/Individual: {Client Name: string: Legal name of the client or company}
- Primary Contact: {Client Contact: string: Name of primary contact person}
- Email: {Client Email: string: Client contact email address}
- Wallet Address: {Client Address: address: The wallet address that will fund this agreement: _client: none}

**Contractor:**
- Company/Individual: {Contractor Name: string: Legal name of the contractor or company}
- Primary Contact: {Contractor Contact: string: Name of primary contact person}
- Email: {Contractor Email: string: Contractor contact email address}
- Wallet Address: {Contractor Address: address: The wallet address that will receive retainer payments: _contractor: none}

The Client and Contractor are collectively referred to as the "Parties."

---

## 2. Retainer Overview

**Start Date:** {Start Date: date: Date when services are expected to begin}

**Services Description:**

{Services Description: string: Detailed description of the ongoing services to be provided under this retainer}

---

## 3. Payment Terms

### 3.1 Retainer Fee

The Client agrees to pay the Contractor a retainer fee as follows:

**Payment Amount:** {Monthly Rate: currency: Amount paid each billing period: _monthlyRate: toWei}

**Payment Token:** {Payment Token: address: Token address for payment (0x0 for native ETH): _paymentToken: none}

**Currency:** {Currency Symbol: string: Currency symbol (ETH, USDC, etc.)}

**Billing Period:** {Period Duration: duration: Length of each billing period: _periodDuration: toSeconds}

### 3.2 Streaming Payment Model

This Agreement uses a **real-time streaming payment model**:

1. The Client shall deposit the full period amount into escrow at the start of each billing period.
2. Payment accrues to the Contractor continuously from the moment of deposit.
3. The Contractor may claim accrued payment at any time during the period.
4. The claimable amount is calculated as: `(period rate × elapsed time) / period duration`
5. Upon completion of the billing period, any unclaimed balance may be claimed by the Contractor.

### 3.3 Renewal

At the end of each billing period, the Client may fund the next period to continue services. If no funding is provided, the Agreement remains in effect but services may be suspended until the next period is funded.

---

## 4. Scope of Services

### 4.1 Services

The Contractor shall provide the services described in Section 2 above. Services shall:

- Be performed in a professional, workmanlike manner
- Comply with industry-standard practices
- Be delivered within reasonable timeframes as mutually agreed

### 4.2 Availability

The Contractor agrees to be reasonably available during the billing period to perform services as requested by the Client. Specific availability expectations:

{Availability Expectations: string: Expected hours, response times, or availability requirements}

### 4.3 Change in Scope

Any material changes to the scope of services must be agreed upon by both Parties. Changes may require:

- Amendment to this Agreement
- Adjustment of the retainer fee
- Creation of a separate project agreement

---

## 5. Cancellation

### 5.1 Notice Period

Either Party may cancel this Agreement by providing written notice. The notice period required is:

**Notice Period:** {Notice Period Days: integer: Days of advance notice required to cancel: _noticePeriodDays: none}

### 5.2 Cancellation Process

1. Either Party initiates cancellation through the on-chain mechanism.
2. The notice period begins from the time of initiation.
3. Services continue during the notice period.
4. After the notice period elapses, cancellation may be executed.

### 5.3 Prorated Settlement

Upon cancellation:

1. The Contractor receives payment prorated for services rendered up to the effective cancellation date.
2. The calculation is: `(period rate × days worked) / period duration`
3. The remaining balance is refunded to the Client.
4. All prorated calculations are handled automatically by the smart contract.

---

## 6. Intellectual Property

### 6.1 Ownership

Upon receipt of payment for each billing period, all intellectual property rights in the work product created during that period shall transfer to the Client, including but not limited to:

- Source code and documentation
- Designs, graphics, and user interfaces
- Reports, analyses, and recommendations
- Any related materials created under this Agreement

### 6.2 Contractor's Reserved Rights

The Contractor retains the right to use:

- General knowledge, skills, and experience gained during the engagement
- Pre-existing tools, libraries, or frameworks owned by the Contractor (subject to license)
- Open-source components (subject to their respective licenses)

---

## 7. Confidentiality

Both Parties agree to maintain the confidentiality of any proprietary information disclosed during this engagement. This obligation shall survive the termination of this Agreement for a period of **{Confidentiality Period: integer: Years confidentiality obligations remain in effect} year(s)**.

---

## 8. Dispute Resolution

### 8.1 On-Chain Resolution

Any disputes regarding payment calculations or service delivery shall be resolved through the on-chain mechanisms defined in the smart contract.

### 8.2 Mediation

For disputes not resolvable on-chain, the Parties agree to first attempt resolution through good-faith negotiation, followed by mediation if necessary.

### 8.3 Governing Law

For matters not addressed by on-chain resolution, this Agreement shall be governed by the laws of {Governing Jurisdiction: string: State or country whose laws govern this agreement}.

---

## 9. Termination

### 9.1 Termination for Convenience

Either Party may terminate this Agreement in accordance with the cancellation provisions in Section 5.

### 9.2 Termination for Cause

Either Party may terminate immediately if the other Party:

- Materially breaches this Agreement and fails to cure within {Cure Period Days: integer: Days to cure a breach before termination} day(s) of notice
- Becomes insolvent or files for bankruptcy
- Engages in fraudulent or illegal conduct

Upon termination for cause by the Client due to Contractor's breach, the Client may recover unused funds from escrow. Upon termination for cause by the Contractor due to Client's breach, the Contractor is entitled to payment for all services rendered.

---

## 10. Representations and Warranties

### 10.1 Contractor Represents

- The Contractor has the skills, qualifications, and experience to perform the services
- The work product will be original work and will not infringe any third-party rights
- The Contractor will comply with all applicable laws and regulations

### 10.2 Client Represents

- The Client has the authority to enter into this Agreement
- The Client will provide timely feedback and direction
- The Client has secured or will secure the necessary funds to fulfill payment obligations

---

## 11. Limitation of Liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER PARTY SHALL BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES ARISING OUT OF THIS AGREEMENT.

The total liability of either Party shall not exceed the total amount paid or payable under this Agreement during the twelve (12) months preceding the claim.

---

## 12. Miscellaneous

### 12.1 Entire Agreement

This Agreement, together with the on-chain smart contract, constitutes the entire agreement between the Parties and supersedes all prior negotiations, representations, or agreements.

### 12.2 Amendments

This Agreement may only be amended by mutual written consent of both Parties, which may be recorded on-chain.

### 12.3 Notices

All notices shall be delivered to the wallet addresses specified above or to any updated address provided by a Party.

### 12.4 Severability

If any provision of this Agreement is found to be unenforceable, the remaining provisions shall continue in full force and effect.

### 12.5 Independent Contractor

The Contractor is an independent contractor and not an employee of the Client. Nothing in this Agreement creates an employment, partnership, or agency relationship.

---

## 13. Signatures

This Agreement is executed electronically via cryptographic signature on the blockchain. By signing, each Party acknowledges that they have read, understood, and agree to be bound by the terms of this Agreement.

**Client Signature:** Recorded on-chain from {Client Address: address: Client's signing wallet: _client: none}

**Contractor Signature:** Recorded on-chain from {Contractor Address: address: Contractor's signing wallet: _contractor: none}

---

*This document is cryptographically linked to a Papre Agreement smart contract. The on-chain record serves as the authoritative source for payment streaming, proration calculations, and cancellation enforcement.*
