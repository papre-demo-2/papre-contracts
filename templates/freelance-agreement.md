# Freelance Service Agreement

**Agreement ID:** This Agreement is recorded on-chain upon execution.

**Effective Date:** {Effective Date: date: Date the agreement becomes effective}

---

## 1. Parties

This Freelance Service Agreement ("Agreement") is entered into by and between:

**Client:**
- Company/Individual: {Client Name: string: Legal name of the client or company}
- Primary Contact: {Client Contact: string: Name of primary contact person}
- Email: {Client Email: string: Client contact email address}
- Wallet Address: {Client Address: address: The wallet address that will fund this agreement: _client: none}

**Freelancer:**
- Company/Individual: {Freelancer Name: string: Legal name of the freelancer or company}
- Primary Contact: {Freelancer Contact: string: Name of primary contact person}
- Email: {Freelancer Email: string: Freelancer contact email address}
- Wallet Address: {Freelancer Address: address: The wallet address that will receive payment: _freelancer: none}

The Client and Freelancer are collectively referred to as the "Parties."

---

## 2. Service Overview

**Service Description:**

{Service Description: string: Detailed description of the freelance services to be provided}

**Start Date:** {Start Date: date: Expected start date for service delivery}

**End Date:** {End Date: date: Expected completion date for all services}

---

## 3. Payment Terms

### 3.1 Total Payment

The Client agrees to pay the Freelancer the following total amount for completion of all services:

**Payment Amount:** {Payment Amount: currency: Total fixed payment for the services: _paymentAmount: toWei}

**Payment Token:** {Payment Token: address: Token address for payment (0x0 for native ETH): _paymentToken: none}

**Currency:** {Currency Symbol: string: Currency symbol (ETH, USDC, etc.)}

### 3.2 Payment Process

1. Upon both Parties signing this Agreement, the Client shall deposit the full payment amount into escrow.
2. The escrowed funds are held securely by the smart contract until conditions are met.
3. When the Freelancer marks work as delivered and the Client approves, payment is released automatically.
4. If the Client does not respond within a reasonable timeframe, the Freelancer may initiate dispute resolution.

### 3.3 Cancellation Fee

In the event of cancellation before work completion:

**Cancellation Fee:** {Cancellation Fee: integer: Percentage of payment retained by Freelancer if cancelled: _cancellationFeeBps: toBps}%

- If the Client cancels after funding but before delivery, the Freelancer receives the cancellation fee as compensation.
- If the Freelancer cancels, the Client receives a full refund of escrowed funds.
- The remaining balance after any cancellation fee is returned to the Client.

---

## 4. Scope of Work

### 4.1 Deliverables

The Freelancer shall deliver the work as specified in the Service Description above. All deliverables shall:

- Meet the specifications described in this Agreement
- Be delivered in a professional, workmanlike manner
- Comply with industry-standard practices and documentation requirements
- Include any necessary documentation, as mutually agreed

### 4.2 Change Requests

Any changes to the scope of work must be agreed upon by both Parties. Material changes may require:

- Amendment to this Agreement
- Adjustment of the payment amount
- Extension of the completion deadline

---

## 5. Delivery and Approval

### 5.1 Delivery

Upon completion of the services, the Freelancer shall:

1. Mark the work as delivered through the on-chain mechanism
2. Provide all agreed-upon deliverables to the Client
3. Include a description or hash of the delivered work

### 5.2 Approval

Upon delivery:

1. The Client shall review the deliverables
2. If satisfied, the Client approves the work, triggering automatic payment release
3. If issues exist, the Client may request revisions or initiate dispute resolution
4. The Freelancer should address any legitimate concerns promptly

---

## 6. Intellectual Property

### 6.1 Ownership

Upon receipt of full payment, all intellectual property rights in the deliverables shall transfer to the Client, including but not limited to:

- Source code and object code
- Documentation and specifications
- Designs, graphics, and user interfaces
- Any related materials created under this Agreement

### 6.2 Freelancer's Reserved Rights

The Freelancer retains the right to use:

- General knowledge, skills, and experience gained during the project
- Pre-existing tools, libraries, or frameworks owned by the Freelancer (subject to license)
- Open-source components (subject to their respective licenses)

---

## 7. Confidentiality

Both Parties agree to maintain the confidentiality of any proprietary information disclosed during this engagement. This obligation shall survive the termination of this Agreement for a period of **{Confidentiality Period: integer: Years confidentiality obligations remain in effect} year(s)**.

---

## 8. Dispute Resolution

### 8.1 On-Chain Resolution

Any disputes regarding deliverable quality or payment shall be resolved through the on-chain mechanisms defined in the smart contract.

### 8.2 Mediation

For disputes not resolvable on-chain, the Parties agree to first attempt resolution through good-faith negotiation, followed by mediation if necessary.

### 8.3 Governing Law

For matters not addressed by on-chain resolution, this Agreement shall be governed by the laws of {Governing Jurisdiction: string: State or country whose laws govern this agreement}.

---

## 9. Termination

### 9.1 Termination for Convenience

Either Party may cancel this Agreement in accordance with the cancellation provisions in Section 3.3. Notice of termination should be provided with at least **{Termination Notice Days: integer: Days of written notice required for termination} day(s)** advance notice when practicable.

### 9.2 Termination for Cause

Either Party may terminate immediately if the other Party:

- Materially breaches this Agreement and fails to cure within {Cure Period Days: integer: Days to cure a breach before termination} day(s) of notice
- Becomes insolvent or files for bankruptcy
- Engages in fraudulent or illegal conduct

Upon termination for cause by the Client due to Freelancer's breach, the Client may recover all escrowed funds. Upon termination for cause by the Freelancer due to Client's breach, the Freelancer is entitled to payment for all completed work.

---

## 10. Representations and Warranties

### 10.1 Freelancer Represents

- The Freelancer has the skills, qualifications, and experience to perform the services
- The deliverables will be original work and will not infringe any third-party rights
- The Freelancer will comply with all applicable laws and regulations

### 10.2 Client Represents

- The Client has the authority to enter into this Agreement
- The Client will provide timely feedback and approvals
- The Client has secured or will secure the necessary funds to fulfill payment obligations

---

## 11. Limitation of Liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER PARTY SHALL BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES ARISING OUT OF THIS AGREEMENT.

The total liability of either Party shall not exceed the total amount paid or payable under this Agreement.

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

The Freelancer is an independent contractor and not an employee of the Client. Nothing in this Agreement creates an employment, partnership, or agency relationship.

---

## 13. Signatures

This Agreement is executed electronically via cryptographic signature on the blockchain. By signing, each Party acknowledges that they have read, understood, and agree to be bound by the terms of this Agreement.

**Client Signature:** Recorded on-chain from {Client Address: address: Client's signing wallet: _client: none}

**Freelancer Signature:** Recorded on-chain from {Freelancer Address: address: Freelancer's signing wallet: _freelancer: none}

---

*This document is cryptographically linked to a Papre Agreement smart contract. The on-chain record serves as the authoritative source for payment release, cancellation enforcement, and dispute resolution.*
