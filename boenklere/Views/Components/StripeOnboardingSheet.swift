import SwiftUI

struct StripeOnboardingSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("For at Boenklere skal kunne betale deg for oppdrag, må du fullføre en enkel onboarding hos vår betalingspartner Stripe.")
                        .font(.body)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dette er nødvendig for å:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        bulletPoint("Bekrefte hvem som mottar pengene")
                        bulletPoint("Sørge for trygge og riktige utbetalinger")
                        bulletPoint("Følge gjeldende lover og regler")
                    }

                    Text("Onboardingen tar bare noen få minutter, og all informasjon håndteres sikkert av Stripe.")
                        .font(.body)
                        .foregroundColor(.primary)

                    Text("Onboardingen vil ikke vises igjen etter at den er fullført.")
                        .font(.body)
                        .foregroundColor(.primary)

                    Text("Velger du Trygg betaling, betaler oppdragsgiver inn beløpet til oss først, og vi utbetaler videre til deg når jobben er gjort.")
                        .font(.body)
                        .foregroundColor(.primary)

                    HStack(alignment: .top, spacing: 8) {
                        Text("👉")
                        Text("Dersom du ikke ønsker å gå gjennom onboardingen, kan du avtale betaling direkte med oppdragsgiver. Stripe-løsningen er ment som en ekstra sikkerhet for deg.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 12) {
                        Button(action: onContinue) {
                            BoenklereActionButtonLabel(
                                title: "Fortsett til Stripe",
                                systemImage: "arrow.right.circle.fill"
                            )
                        }
                        .buttonStyle(.plain)

                        Button(action: onCancel) {
                            BoenklereActionButtonLabel(
                                title: "Avbryt",
                                systemImage: "xmark",
                                textColor: .secondary,
                                fillColor: Color(.systemGray5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var sheetHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 5)
                .padding(.bottom, 3)

            HStack {
                Text("Stripe onboarding")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.gray, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundColor(.green)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
}
