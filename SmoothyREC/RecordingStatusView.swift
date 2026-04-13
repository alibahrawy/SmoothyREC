//
//  RecordingStatusView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI

struct RecordingStatusView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var isPaused = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Header with recording indicator
            HStack(spacing: 12) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
                    .opacity(isPaused ? 0.5 : 1.0)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPaused ? "Recording Paused" : "Recording...")
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text(appDelegate.recordingCoordinator.formattedDuration)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                }
                
                Spacer()
            }
            
            Divider()
            
            // Active recorders info
            VStack(alignment: .leading, spacing: 6) {
                Text("Active Sources")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    RecorderBadge(
                        icon: "display",
                        label: "Screen",
                        isActive: appDelegate.recordingCoordinator.screenRecorderState.isRecording || isPaused
                    )
                    
                    if appDelegate.recordingCoordinator.micRecorderState.isRecording || isPaused {
                        RecorderBadge(
                            icon: "mic.fill",
                            label: "Mic",
                            isActive: true
                        )
                    }
                    
                    if appDelegate.recordingCoordinator.cameraRecorderState.isRecording || isPaused {
                        RecorderBadge(
                            icon: "video.fill",
                            label: "Camera",
                            isActive: true
                        )
                    }
                }
            }
            
            Divider()
            
            // Control buttons
            VStack(spacing: 8) {
                Button(action: {
                    togglePauseResume()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        Text(isPaused ? "Resume Recording" : "Pause Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(isPaused ? .green : .orange)
                .controlSize(.large)
                
                Button(action: {
                    stopRecording()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("Stop Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onReceive(appDelegate.recordingCoordinator.$state) { state in
            // Update pause state based on coordinator
            if case .paused = state {
                isPaused = true
            } else if case .recording = state {
                isPaused = false
            }
        }
    }
    
    private func togglePauseResume() {
        Task {
            if isPaused {
                await appDelegate.recordingCoordinator.resume()
                isPaused = false
            } else {
                await appDelegate.recordingCoordinator.pause()
                isPaused = true
            }
        }
    }
    
    private func stopRecording() {
        appDelegate.stopRecordingFromStatusBar()
    }
}

// MARK: - Recorder Badge

struct RecorderBadge: View {
    let icon: String
    let label: String
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(label)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
        .foregroundColor(isActive ? .green : .secondary)
        .cornerRadius(6)
    }
}

#Preview {
    RecordingStatusView()
        .environmentObject(AppDelegate())
}