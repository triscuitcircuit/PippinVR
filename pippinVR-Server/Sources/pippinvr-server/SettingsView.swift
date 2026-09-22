import SwiftUI

struct SettingsView: View {

    let session: PipelineSession

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            
            VStack(alignment: .leading) {
                Text("Virtual Displays")
                    .font(.headline)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(session.displayNames, id: \.0) { display in
                            Text("\(display.0) - \(display.1)x\(display.2)")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.2))
                                .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 300)
    }
}
