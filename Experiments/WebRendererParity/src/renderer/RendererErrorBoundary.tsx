import { Component, type ErrorInfo, type ReactNode } from "react";

type RendererErrorBoundaryProps = {
  source: string;
  children: ReactNode;
};

type RendererErrorBoundaryState = {
  error: Error | null;
};

export class RendererErrorBoundary extends Component<
  RendererErrorBoundaryProps,
  RendererErrorBoundaryState
> {
  state: RendererErrorBoundaryState = {
    error: null
  };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("Renderer projection failed; showing raw source.", {
      error,
      componentStack: info.componentStack
    });
  }

  componentDidUpdate(previousProps: RendererErrorBoundaryProps) {
    if (
      this.state.error &&
      previousProps.source !== this.props.source
    ) {
      this.setState({ error: null });
    }
  }

  render() {
    if (!this.state.error) {
      return this.props.children;
    }

    return (
      <div className="renderer-error" role="alert">
        <strong>Rich rendering failed. Raw source is preserved.</strong>
        <pre>{this.props.source}</pre>
      </div>
    );
  }
}

