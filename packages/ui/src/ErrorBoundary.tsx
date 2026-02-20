import React, { Component, type ReactNode, type ErrorInfo } from "react"

interface ErrorBoundaryProps {
  children: ReactNode
  fallback?: ReactNode
  onError?: (error: Error, errorInfo: ErrorInfo) => void
}

interface ErrorBoundaryState {
  hasError: boolean
  error: Error | null
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props)
    this.state = { hasError: false, error: null }
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error }
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("[Synapsis] React component error:", error, errorInfo)
    this.props.onError?.(error, errorInfo)
  }

  handleRetry = () => {
    this.setState({ hasError: false, error: null })
  }

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) {
        return this.props.fallback
      }

      return (
        <div className="flex flex-col items-center justify-center h-full p-8 text-center">
          <div className="bg-red-900/30 border border-red-700 rounded-lg p-6 max-w-md">
            <h2 className="text-red-300 text-lg font-semibold mb-2">
              Something went wrong
            </h2>
            <p className="text-red-400 text-sm mb-4">
              {this.state.error?.message || "An unexpected error occurred in the UI."}
            </p>
            <button
              onClick={this.handleRetry}
              className="px-4 py-2 bg-red-700 hover:bg-red-600 text-white rounded text-sm"
            >
              Retry
            </button>
          </div>
        </div>
      )
    }

    return this.props.children
  }
}

interface MessageErrorBoundaryProps {
  children: ReactNode
  messageId?: string
}

interface MessageErrorBoundaryState {
  hasError: boolean
  error: Error | null
}

export class MessageErrorBoundary extends Component<
  MessageErrorBoundaryProps,
  MessageErrorBoundaryState
> {
  constructor(props: MessageErrorBoundaryProps) {
    super(props)
    this.state = { hasError: false, error: null }
  }

  static getDerivedStateFromError(error: Error): MessageErrorBoundaryState {
    return { hasError: true, error }
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error(
      `[Synapsis] Message render error (id=${this.props.messageId}):`,
      error,
      errorInfo
    )
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="p-3 bg-red-900/20 border border-red-800 rounded text-red-400 text-sm">
          Failed to render message. Error: {this.state.error?.message}
        </div>
      )
    }

    return this.props.children
  }
}
